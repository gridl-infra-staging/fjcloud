#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$REPO_ROOT"

export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
source "$REPO_ROOT/scripts/lib/env.sh"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE CLOUDFLARE_API_TOKEN CLOUDFLARE_GLOBAL_API_KEY CLOUDFLARE_EMAIL CLOUDFLARE_X_Auth_Email
load_env_file "$FJCLOUD_SECRET_FILE"

if [ -n "${CLOUDFLARE_GLOBAL_API_KEY:-}" ] && [ -n "${CLOUDFLARE_X_Auth_Email:-}" ]; then
  export CLOUDFLARE_API_KEY="$CLOUDFLARE_GLOBAL_API_KEY"
  export CLOUDFLARE_EMAIL="$CLOUDFLARE_X_Auth_Email"
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TF_DIR="$REPO_ROOT/ops/terraform/_shared"
EVID_DIR="$(cd "$(dirname "$0")" && pwd)"

resolve_ssm_param() {
  local param_name="$1"
  aws ssm get-parameter --region "$AWS_REGION" --name "$param_name" --query 'Parameter.Value' --output text
}

resolve_alert_emails_json_from_sns() {
  local env_name="$1"
  local topic_arn
  topic_arn="$(aws sns list-topics --region "$AWS_REGION" --output json | jq -r --arg suffix ":fjcloud-alerts-${env_name}" '.Topics[]?.TopicArn | select(endswith($suffix))' | head -n 1)"
  if [ -z "$topic_arn" ]; then
    echo "[]"
    return 0
  fi

  aws sns list-subscriptions-by-topic \
    --region "$AWS_REGION" \
    --topic-arn "$topic_arn" \
    --output json \
  | jq -c '[.Subscriptions[] | select(.Protocol=="email" or .Protocol=="email-json") | .Endpoint] | unique'
}

resolve_alert_emails_json_from_state() {
  local subscription_addresses
  subscription_addresses="$(terraform state list | rg 'module\.monitoring\.aws_sns_topic_subscription\.email\[' || true)"
  if [ -z "$subscription_addresses" ]; then
    echo "[]"
    return 0
  fi

  printf '%s\n' "$subscription_addresses" \
    | sed -E 's/.*email\["([^"]+)"\]/"\1"/' \
    | jq -s -c 'unique'
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  "$@" &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$cmd_pid" 2>/dev/null || true
      wait "$cmd_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
}

run_env_plan_apply() {
  local env_name="$1"
  local bucket_name="$2"

  local ami_id
  local cloudflare_zone_id
  local alert_emails_json
  local tfvars_file
  local full_plan_file
  local full_plan_err_file
  local plan_file
  local apply_file

  ami_id="$(resolve_ssm_param "/fjcloud/${env_name}/aws_ami_id")"
  cloudflare_zone_id="$(resolve_ssm_param "/fjcloud/${env_name}/cloudflare_zone_id")"

  full_plan_file="$EVID_DIR/${env_name}_full_plan_attempt.txt"
  full_plan_err_file="$EVID_DIR/${env_name}_full_plan_attempt.err"
  plan_file="$EVID_DIR/${env_name}_plan.txt"
  apply_file="$EVID_DIR/${env_name}_apply.txt"

  pushd "$TF_DIR" >/dev/null
  terraform init \
    -backend-config="bucket=${bucket_name}" \
    -backend-config="key=terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="dynamodb_table=fjcloud-tflock" \
    -reconfigure > "$EVID_DIR/${env_name}_terraform_init.txt"

  alert_emails_json="$(resolve_alert_emails_json_from_sns "$env_name")"
  if [ "$alert_emails_json" = "[]" ]; then
    alert_emails_json="$(resolve_alert_emails_json_from_state)"
  fi

  if [ "$env_name" = "prod" ] && [ "$alert_emails_json" = "[]" ]; then
    echo "env=prod requires non-empty alert_emails; SNS/state discovery returned empty." >&2
    exit 1
  fi

  # Domain: staging uses staging.flapjack.foo, prod uses flapjack.foo (no SSM param exists)
  local domain
  if [ "$env_name" = "staging" ]; then
    domain="staging.flapjack.foo"
  else
    domain="flapjack.foo"
  fi

  # Resolve current Lambda image tags to avoid reverting to Terraform defaults
  local cl_image_tag se_image_tag
  cl_image_tag="$(aws lambda get-function --function-name "fjcloud-${env_name}-customer-loop-canary" \
    --query 'Code.ImageUri' --output text --region "$AWS_REGION" 2>/dev/null | sed 's/.*://')"
  se_image_tag="$(aws lambda get-function --function-name "fjcloud-${env_name}-support-email-canary" \
    --query 'Code.ImageUri' --output text --region "$AWS_REGION" 2>/dev/null | sed 's/.*://')"

  jq -n \
    --arg env "$env_name" \
    --arg ami_id "$ami_id" \
    --arg cloudflare_zone_id "$cloudflare_zone_id" \
    --argjson alert_emails "$alert_emails_json" \
    --arg domain "$domain" \
    --arg cl_tag "${cl_image_tag:-pending-publication}" \
    --arg se_tag "${se_image_tag:-latest}" \
    '{env:$env,ami_id:$ami_id,cloudflare_zone_id:$cloudflare_zone_id,alert_emails:$alert_emails,domain:$domain,canary_image:{tag:$cl_tag},support_email_canary_image_tag:$se_tag}' \
    > "$EVID_DIR/${env_name}_inputs.json"

  tfvars_file="$(mktemp "/tmp/stage6_${env_name}_tfvars_XXXXXX.json")"
  cp "$EVID_DIR/${env_name}_inputs.json" "$tfvars_file"

  # Always use targeted monitoring scope to avoid non-monitoring drift
  terraform plan \
    -target=module.monitoring \
    -target=terraform_data.prod_alert_emails_guard \
    -var-file="$tfvars_file" > "$plan_file"
  terraform apply -auto-approve \
    -target=module.monitoring \
    -target=terraform_data.prod_alert_emails_guard \
    -var-file="$tfvars_file" > "$apply_file"
  printf 'targeted_monitoring\n' > "$EVID_DIR/${env_name}_apply_mode.txt"
  popd >/dev/null

  rm -f "$tfvars_file"
}

run_env_plan_apply staging fjcloud-tfstate-staging
run_env_plan_apply prod fjcloud-tfstate-prod

run_with_timeout 300 bash "$REPO_ROOT/scripts/canary/contracts/lambda_canary_invoke_contract.sh" staging customer-loop > "$EVID_DIR/staging_customer_loop_invoke.txt" 2>&1
run_with_timeout 300 bash "$REPO_ROOT/scripts/canary/contracts/lambda_canary_invoke_contract.sh" staging support-email > "$EVID_DIR/staging_support_email_invoke.txt" 2>&1
run_with_timeout 300 bash "$REPO_ROOT/scripts/canary/contracts/lambda_canary_invoke_contract.sh" prod customer-loop > "$EVID_DIR/prod_customer_loop_invoke.txt" 2>&1
run_with_timeout 300 bash "$REPO_ROOT/scripts/canary/contracts/lambda_canary_invoke_contract.sh" prod support-email > "$EVID_DIR/prod_support_email_invoke.txt" 2>&1

PROD_ALERTS_TOPIC_ARN="$(aws sns list-topics --region "$AWS_REGION" --output json | jq -r '.Topics[]?.TopicArn | select(endswith(":fjcloud-alerts-prod"))' | head -n 1)"
if [ -n "$PROD_ALERTS_TOPIC_ARN" ]; then
  aws sns list-subscriptions-by-topic --region "$AWS_REGION" --topic-arn "$PROD_ALERTS_TOPIC_ARN" --output json > "$EVID_DIR/prod_sns_subscriptions.json"
else
  echo '{"warning":"fjcloud-alerts-prod topic not found"}' > "$EVID_DIR/prod_sns_subscriptions.json"
fi
