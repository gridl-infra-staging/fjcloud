#!/usr/bin/env bash
# Static validation tests for Stage 5 support-email canary Terraform substrate.
# TDD: this test locks ownership, delegation, and secret-boundary contracts.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

support_tf_file="ops/terraform/monitoring/support_email_canary.tf"
monitor_main_file="ops/terraform/monitoring/main.tf"
monitor_vars_file="ops/terraform/monitoring/variables.tf"
shared_main_file="ops/terraform/_shared/main.tf"
shared_vars_file="ops/terraform/_shared/variables.tf"
publish_script_file="ops/terraform/publish_support_email_canary_image.sh"
packaging_dir="ops/terraform/support_email_canary"
dockerfile_file="$packaging_dir/Dockerfile"
lambda_handler_file="$packaging_dir/lambda_handler.py"

assert_resource_ownership() {
  local resource_type="$1"
  local owner_file="$2"
  local description="$3"
  local hits

  hits=$(rg -n "^[[:space:]]*resource[[:space:]]+\"${resource_type}\"[[:space:]]+\"support_email_canary[^\"]*\"" ops/terraform/monitoring || true)
  if [[ -z "$hits" ]]; then
    fail "$description (no support_email_canary ${resource_type} resource found under ops/terraform/monitoring)"
    return
  fi

  if echo "$hits" | rg -qv "^${owner_file}:"; then
    fail "$description (${resource_type} found outside ${owner_file})"
    return
  fi

  pass "$description"
}

assert_tf_variable_default() {
  local file="$1"
  local variable_name="$2"
  local expected_default="$3"
  local label="$4"

  if strip_comments "$file" | awk -v target_var="$variable_name" -v expected="$expected_default" '
    BEGIN {
      in_block = 0
      depth = 0
      saw_variable = 0
      matched_default = 0
    }
    {
      line = $0
      if (!in_block && line ~ "^[[:space:]]*variable[[:space:]]+\"" target_var "\"[[:space:]]*\\{[[:space:]]*$") {
        in_block = 1
        depth = 1
        saw_variable = 1
        next
      }

      if (!in_block) {
        next
      }

      if (line ~ "^[[:space:]]*default[[:space:]]*=[[:space:]]*" expected "[[:space:]]*$") {
        matched_default = 1
      }

      opens = gsub(/\{/, "{", line)
      closes = gsub(/\}/, "}", line)
      depth += (opens - closes)
      if (depth <= 0) {
        exit matched_default ? 0 : 2
      }
    }
    END {
      if (!saw_variable) {
        exit 3
      }
      if (!matched_default) {
        exit 2
      }
      exit 0
    }
  '; then
    pass "$label"
  else
    fail "$label"
  fi
}

echo ""
echo "=== Stage 5 Static Tests: Support Email Canary Terraform Contract ==="
echo ""

echo "--- Ownership seams ---"
assert_file_exists "$support_tf_file" "monitoring/support_email_canary.tf exists"
assert_file_exists "$monitor_main_file" "monitoring/main.tf exists"
assert_file_exists "$monitor_vars_file" "monitoring/variables.tf exists"
assert_file_exists "$shared_main_file" "_shared/main.tf exists"
assert_file_exists "$shared_vars_file" "_shared/variables.tf exists"
assert_contains_active "$shared_main_file" 'module "monitoring"' "root wiring keeps module \"monitoring\" owner"
assert_contains_active "$shared_main_file" 'source[[:space:]]*=[[:space:]]*"../monitoring"' "root monitoring source remains ../monitoring"
assert_not_contains_active "$shared_main_file" 'module "support_email_canary"' "root wiring does not introduce parallel support_email_canary module"
assert_not_contains_active "$monitor_main_file" 'support_email_canary' "monitoring/main.tf remains alarm-focused (no support_email_canary resources)"

assert_resource_ownership "aws_ecr_repository" "$support_tf_file" "ECR repository owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_cloudwatch_log_group" "$support_tf_file" "Canary log group owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_lambda_function" "$support_tf_file" "Canary Lambda owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_cloudwatch_event_rule" "$support_tf_file" "Canary EventBridge rule owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_cloudwatch_event_target" "$support_tf_file" "Canary EventBridge target owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_lambda_permission" "$support_tf_file" "Canary Lambda invoke permission owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_iam_role" "$support_tf_file" "Canary IAM role owner is monitoring/support_email_canary.tf"
assert_resource_ownership "aws_iam_role_policy" "$support_tf_file" "Canary IAM role policy owner is monitoring/support_email_canary.tf"

echo ""
echo "--- Stage 3 roundtrip runtime contract seams ---"
assert_contains_active "$monitor_vars_file" 'variable[[:space:]]+"support_email_canary_inbound_roundtrip_s3_uri"' "monitoring variable contract defines inbound roundtrip S3 URI"
assert_contains_active "$monitor_vars_file" 'default[[:space:]]*=[[:space:]]*"s3://flapjack-cloud-releases/e2e-emails/"' "monitoring inbound roundtrip S3 URI default matches Stage 2 contract"
assert_contains_active "$monitor_vars_file" 'variable[[:space:]]+"support_email_canary_recipient_domain_default"' "monitoring variable contract defines recipient domain default"
assert_contains_active "$monitor_vars_file" 'default[[:space:]]*=[[:space:]]*"test.flapjack.foo"' "monitoring recipient domain default matches Stage 2 contract"
assert_contains_active "$monitor_vars_file" 'variable[[:space:]]+"support_email_canary_recipient_local_part_default"' "monitoring variable contract defines optional recipient local-part default"
assert_tf_variable_default "$monitor_vars_file" "support_email_canary_recipient_local_part_default" "\"\"" "monitoring local-part default remains empty for nonce-based addressing"
assert_contains_active "$shared_vars_file" 'variable[[:space:]]+"support_email_canary_inbound_roundtrip_s3_uri"' "_shared variable passthrough defines inbound roundtrip S3 URI"
assert_contains_active "$shared_vars_file" 'variable[[:space:]]+"support_email_canary_recipient_domain_default"' "_shared variable passthrough defines recipient domain default"
assert_contains_active "$shared_vars_file" 'variable[[:space:]]+"support_email_canary_recipient_local_part_default"' "_shared variable passthrough defines recipient local-part default"
assert_contains_active "$shared_main_file" 'support_email_canary_inbound_roundtrip_s3_uri[[:space:]]*=[[:space:]]*var\.support_email_canary_inbound_roundtrip_s3_uri' "_shared/main forwards inbound roundtrip S3 URI into monitoring module"
assert_contains_active "$shared_main_file" 'support_email_canary_recipient_domain_default[[:space:]]*=[[:space:]]*var\.support_email_canary_recipient_domain_default' "_shared/main forwards recipient domain default into monitoring module"
assert_contains_active "$shared_main_file" 'support_email_canary_recipient_local_part_default[[:space:]]*=[[:space:]]*var\.support_email_canary_recipient_local_part_default' "_shared/main forwards recipient local-part default into monitoring module"
assert_contains_active "$support_tf_file" 'support_email_canary_inbound_roundtrip_s3_path_segments[[:space:]]*=[[:space:]]*split\("/",[[:space:]]*trimprefix\(var\.support_email_canary_inbound_roundtrip_s3_uri,[[:space:]]*"s3://"\)\)' "monitoring support canary derives bucket/prefix segments from support_email_canary_inbound_roundtrip_s3_uri"
assert_contains_active "$support_tf_file" 'support_email_canary_inbound_roundtrip_s3_prefix_clean[[:space:]]*=[[:space:]]*trim\(local\.support_email_canary_inbound_roundtrip_s3_prefix,[[:space:]]*"/"\)' "monitoring support canary normalizes inbound S3 prefix before IAM use"
assert_contains_active "$support_tf_file" 'INBOUND_ROUNDTRIP_S3_URI[[:space:]]*=[[:space:]]*var\.support_email_canary_inbound_roundtrip_s3_uri' "Lambda env wiring passes INBOUND_ROUNDTRIP_S3_URI from Terraform variable"
assert_contains_active "$support_tf_file" 'INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN[[:space:]]*=[[:space:]]*var\.support_email_canary_recipient_domain_default' "Lambda env wiring passes INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN default"
assert_contains_active "$support_tf_file" 'INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART[[:space:]]*=[[:space:]]*var\.support_email_canary_recipient_local_part_default' "Lambda env wiring supports optional INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART default"
assert_contains_active "$support_tf_file" 'Sid[[:space:]]*=[[:space:]]*"AllowCanaryListInboundBucket"' "IAM contract keeps dedicated ListBucket statement for inbound roundtrip bucket"
assert_contains_active "$support_tf_file" 'Resource[[:space:]]*=[[:space:]]*local\.support_email_canary_inbound_roundtrip_bucket_arn' "ListBucket scope is derived from parsed inbound roundtrip bucket ARN local"
assert_contains_active "$support_tf_file" '"s3:prefix"[[:space:]]*=[[:space:]]*local\.support_email_canary_inbound_roundtrip_list_prefixes' "ListBucket s3:prefix condition is derived from parsed inbound roundtrip prefix local"
assert_contains_active "$support_tf_file" 'Sid[[:space:]]*=[[:space:]]*"AllowCanaryReadInboundObjects"' "IAM contract keeps dedicated GetObject statement for inbound roundtrip objects"
assert_contains_active "$support_tf_file" 'Resource[[:space:]]*=[[:space:]]*local\.support_email_canary_inbound_roundtrip_object_arn' "GetObject scope is derived from parsed inbound roundtrip object ARN local"

echo ""
echo "--- Packaging and delegation seams ---"
assert_file_exists "$publish_script_file" "publish_support_email_canary_image.sh exists"
if [[ -x "$publish_script_file" ]]; then
  pass "publish_support_email_canary_image.sh is executable"
else
  fail "publish_support_email_canary_image.sh is executable"
fi
assert_file_exists "$dockerfile_file" "support_email_canary Dockerfile exists"
assert_file_exists "$lambda_handler_file" "support_email_canary lambda_handler.py exists"
assert_file_contains "$publish_script_file" 'docker build' "publish script builds image"
assert_file_contains "$publish_script_file" 'docker push' "publish script pushes image"
assert_file_contains "$publish_script_file" 'support_email_canary/Dockerfile' "publish script uses support_email_canary Dockerfile"
assert_file_contains "$dockerfile_file" 'scripts/canary/support_email_deliverability.sh' "Dockerfile copies canonical canary wrapper owner"
assert_file_contains "$dockerfile_file" 'scripts/validate_inbound_email_roundtrip.sh' "Dockerfile copies canonical roundtrip probe owner"
assert_file_contains "$lambda_handler_file" 'support_email_deliverability.sh' "lambda handler delegates runtime to support_email_deliverability.sh"
assert_file_contains "$lambda_handler_file" 'validate_inbound_email_roundtrip.sh' "lambda handler contract references delegated roundtrip owner"

support_packaging_probe_impl_hits="$(rg -n 'sesv2 send-email|Authentication-Results|alert_dispatch_send_critical' "$packaging_dir" || true)"
if [[ -z "$support_packaging_probe_impl_hits" ]]; then
  pass "support_email_canary packaging seam does not reimplement probe/alert business logic"
else
  fail "support_email_canary packaging seam does not reimplement probe/alert business logic"
fi

echo ""
echo "--- Secret boundary (SSM names only, no webhook values) ---"
assert_contains_active "$support_tf_file" '/fjcloud/\$\{var\.env\}/slack_webhook_url' "Terraform references slack webhook SSM parameter by name contract"
assert_contains_active "$support_tf_file" '/fjcloud/\$\{var\.env\}/discord_webhook_url' "Terraform references discord webhook SSM parameter by name contract"
assert_contains_active "$support_tf_file" 'ssm:GetParameter' "IAM policy allows SSM GetParameter"
assert_contains_active "$support_tf_file" 'ssm:GetParameters' "IAM policy allows SSM GetParameters"
assert_not_contains_active "$support_tf_file" 'resource[[:space:]]+"aws_ssm_parameter"' "Terraform does not create webhook aws_ssm_parameter resources"
assert_file_not_contains "$support_tf_file" 'hooks\.slack\.com/services/' "Terraform does not embed Slack webhook URL values"
assert_file_not_contains "$support_tf_file" 'discord\.com/api/webhooks/' "Terraform does not embed Discord webhook URL values"

echo ""
echo "--- IAM least privilege and publication ownership ---"
assert_contains_active "$support_tf_file" 'Sid[[:space:]]*=[[:space:]]*"AllowCanaryListInboundBucket"' "IAM policy defines dedicated ListBucket statement"
assert_contains_active "$support_tf_file" 'Condition[[:space:]]*=' "ListBucket statement uses condition block for prefix scoping"
assert_contains_active "$support_tf_file" 's3:prefix' "ListBucket statement scopes allowed prefixes via s3:prefix"
assert_file_not_contains "$publish_script_file" 'aws[[:space:]]+ecr[[:space:]]+create-repository' "publish script does not create Terraform-owned ECR repositories"

test_summary "Support email canary static checks"
