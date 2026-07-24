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

verify_env() {
  local env_name="$1"
  local bucket_name="$2"
  local customer_rule_name

  pushd "$TF_DIR" >/dev/null
  terraform init \
    -backend-config="bucket=${bucket_name}" \
    -backend-config="key=terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="dynamodb_table=fjcloud-tflock" \
    -reconfigure > "$EVID_DIR/${env_name}_verify_terraform_init.txt"

  customer_rule_name="$(terraform output -raw customer_loop_canary_schedule_rule_name)"
  popd >/dev/null

  aws events describe-rule --region "$AWS_REGION" --name "$customer_rule_name" --output json > "$EVID_DIR/${env_name}_customer_loop_rule.json"
  aws events list-targets-by-rule --region "$AWS_REGION" --rule "$customer_rule_name" --output json > "$EVID_DIR/${env_name}_customer_loop_targets.json"

  local support_rule_name="fjcloud-${env_name}-support-email-canary-schedule"
  aws events describe-rule --region "$AWS_REGION" --name "$support_rule_name" --output json > "$EVID_DIR/${env_name}_support_email_rule.json"
  aws events list-targets-by-rule --region "$AWS_REGION" --rule "$support_rule_name" --output json > "$EVID_DIR/${env_name}_support_email_targets.json"

  aws cloudwatch describe-alarms \
    --region "$AWS_REGION" \
    --alarm-names "fjcloud-${env_name}-customer-loop-canary-not-running" "fjcloud-${env_name}-support-email-canary-not-running" \
    --output json > "$EVID_DIR/${env_name}_alarms.json"
}

verify_env staging fjcloud-tfstate-staging
verify_env prod fjcloud-tfstate-prod
