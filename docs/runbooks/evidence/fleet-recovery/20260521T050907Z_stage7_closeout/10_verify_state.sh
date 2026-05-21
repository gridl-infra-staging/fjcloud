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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

resolve_alert_emails_json_from_state() {
  local subscription_addresses
  subscription_addresses="$(terraform state list | rg "module\\.monitoring\\.aws_sns_topic_subscription\\.email\\[" || true)"
  if [ -z "$subscription_addresses" ]; then
    echo "[]"
    return 0
  fi

  printf "%s\n" "$subscription_addresses" \
    | sed -E "s/.*email\[\"([^\"]+)\"\]/\"\1\"/" \
    | jq -s -c "unique"
}

resolve_prod_alerts_topic_arn() {
  aws sns list-topics --region "$AWS_REGION" --output json \
    | jq -r ".Topics[]?.TopicArn | select(endswith(\":fjcloud-alerts-prod\"))" \
    | head -n 1
}

pushd "$TF_DIR" >/dev/null
terraform init \
  -backend-config="bucket=fjcloud-tfstate-prod" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=fjcloud-tflock" \
  -reconfigure > "$EVID_DIR/prod_verify_terraform_init.txt"

customer_rule_name="$(terraform output -raw customer_loop_canary_schedule_rule_name)"
expected_alert_emails_json="$(resolve_alert_emails_json_from_state)"
popd >/dev/null

support_rule_name="fjcloud-prod-support-email-canary-schedule"

aws events describe-rule --region "$AWS_REGION" --name "$customer_rule_name" --output json > "$EVID_DIR/prod_customer_loop_rule.json"
aws events list-targets-by-rule --region "$AWS_REGION" --rule "$customer_rule_name" --output json > "$EVID_DIR/prod_customer_loop_targets.json"
aws events describe-rule --region "$AWS_REGION" --name "$support_rule_name" --output json > "$EVID_DIR/prod_support_email_rule.json"
aws events list-targets-by-rule --region "$AWS_REGION" --rule "$support_rule_name" --output json > "$EVID_DIR/prod_support_email_targets.json"
aws cloudwatch describe-alarms \
  --region "$AWS_REGION" \
  --alarm-names "fjcloud-prod-customer-loop-canary-not-running" "fjcloud-prod-support-email-canary-not-running" \
  --output json > "$EVID_DIR/prod_alarms.json"

prod_alerts_topic_arn="$(resolve_prod_alerts_topic_arn)"
[ -n "$prod_alerts_topic_arn" ] || fail "SNS topic fjcloud-alerts-prod not found"

aws sns list-subscriptions-by-topic \
  --region "$AWS_REGION" \
  --topic-arn "$prod_alerts_topic_arn" \
  --output json > "$EVID_DIR/prod_sns_subscriptions.json"

jq -e ".State == \"ENABLED\"" "$EVID_DIR/prod_customer_loop_rule.json" >/dev/null || fail "customer-loop EventBridge rule is not ENABLED"
jq -e ".State == \"ENABLED\"" "$EVID_DIR/prod_support_email_rule.json" >/dev/null || fail "support-email EventBridge rule is not ENABLED"

jq -e ".Targets | length > 0" "$EVID_DIR/prod_customer_loop_targets.json" >/dev/null || fail "customer-loop EventBridge targets are empty"
jq -e ".Targets | length > 0" "$EVID_DIR/prod_support_email_targets.json" >/dev/null || fail "support-email EventBridge targets are empty"

jq -e ".MetricAlarms | length == 2" "$EVID_DIR/prod_alarms.json" >/dev/null || fail "expected both prod canary non-running alarms"
for alarm_name in fjcloud-prod-customer-loop-canary-not-running fjcloud-prod-support-email-canary-not-running; do
  jq -e --arg alarm_name "$alarm_name" ".MetricAlarms[] | select(.AlarmName == \$alarm_name)" "$EVID_DIR/prod_alarms.json" >/dev/null \
    || fail "missing alarm: $alarm_name"
  jq -e --arg alarm_name "$alarm_name" ".MetricAlarms[] | select(.AlarmName == \$alarm_name) | .TreatMissingData == \"breaching\"" "$EVID_DIR/prod_alarms.json" >/dev/null \
    || fail "alarm $alarm_name does not use TreatMissingData=breaching"
  jq -e --arg alarm_name "$alarm_name" --arg topic_arn "$prod_alerts_topic_arn" ".MetricAlarms[] | select(.AlarmName == \$alarm_name) | (.AlarmActions == [\$topic_arn] and .OKActions == [\$topic_arn])" "$EVID_DIR/prod_alarms.json" >/dev/null \
    || fail "alarm $alarm_name alarm/ok actions do not match canonical paging topic"
done

[ "$expected_alert_emails_json" != "[]" ] || fail "expected prod alert_emails from terraform state is empty"

live_alert_email_endpoints_json="$(jq -c '[.Subscriptions[] | select(.Protocol == "email" or .Protocol == "email-json") | .Endpoint] | unique' "$EVID_DIR/prod_sns_subscriptions.json")"

jq -e -n \
  --argjson expected "$expected_alert_emails_json" \
  --argjson live "$live_alert_email_endpoints_json" \
  '$expected == $live' >/dev/null \
  || fail "live prod alert topic email endpoints drift from terraform canonical set"

live_alert_emails_json="$(jq -c '[.Subscriptions[] | select((.Protocol == "email" or .Protocol == "email-json") and .SubscriptionArn != "PendingConfirmation") | .Endpoint] | unique' "$EVID_DIR/prod_sns_subscriptions.json")"
[ "$live_alert_emails_json" != "[]" ] || fail "live prod alert topic has no confirmed email subscriptions"

jq -e -n \
  --argjson expected "$expected_alert_emails_json" \
  --argjson live "$live_alert_emails_json" \
  '$expected == $live' >/dev/null \
  || fail "live prod alert subscribers drift from terraform canonical set"
