#!/usr/bin/env bash
set -euo pipefail
cd fjcloud_dev
set -a
source .secret/.env.secret
set +a

EVID_DIR="docs/runbooks/evidence/alert_emails/20260521T173845Z_staging"
REPO="fjcloud_dev"

# Mirror the existing Cloudflare auth fallback used in prior evidence scripts.
if [ -n "${CLOUDFLARE_GLOBAL_API_KEY:-}" ] && [ -n "${CLOUDFLARE_X_Auth_Email:-}" ]; then
  export CLOUDFLARE_API_KEY="$CLOUDFLARE_GLOBAL_API_KEY"
  export CLOUDFLARE_EMAIL="$CLOUDFLARE_X_Auth_Email"
fi

STAGING_ALERT_EMAILS_JSON_RAW="$(sed -n 's/^STAGING_ALERT_EMAILS_JSON=//p' .secret/session/alert_emails.env)"
PROD_ALERT_EMAILS_JSON_RAW="$(sed -n 's/^PROD_ALERT_EMAILS_JSON=//p' .secret/session/alert_emails.env)"
printf '%s\n' "$STAGING_ALERT_EMAILS_JSON_RAW" > "$EVID_DIR/staging_inputs_raw.json"
printf '%s\n' "$PROD_ALERT_EMAILS_JSON_RAW" > "$EVID_DIR/prod_inputs_raw.json"

jq -c '[.[] | gsub("^[[:space:]]+|[[:space:]]+$"; "")]' "$EVID_DIR/staging_inputs_raw.json" > "$EVID_DIR/staging_inputs.json"
jq -c '[.[] | gsub("^[[:space:]]+|[[:space:]]+$"; "")]' "$EVID_DIR/prod_inputs_raw.json" > "$EVID_DIR/prod_inputs.json"

jq -e 'type == "array" and all(.[]; type == "string")' "$EVID_DIR/staging_inputs_raw.json" > "$EVID_DIR/validate_raw_staging.txt"
jq -e 'type == "array" and all(.[]; type == "string")' "$EVID_DIR/prod_inputs_raw.json" > "$EVID_DIR/validate_raw_prod.txt"

jq -e 'type == "array" and all(.[]; (type == "string") and ((gsub("^[[:space:]]+|[[:space:]]+$"; "")) != "") and ((gsub("^[[:space:]]+|[[:space:]]+$"; "")) | test("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")))' "$EVID_DIR/staging_inputs.json" > "$EVID_DIR/validate_normalized_staging.txt"
jq -e 'type == "array" and all(.[]; (type == "string") and ((gsub("^[[:space:]]+|[[:space:]]+$"; "")) != "") and ((gsub("^[[:space:]]+|[[:space:]]+$"; "")) | test("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")))' "$EVID_DIR/prod_inputs.json" > "$EVID_DIR/validate_normalized_prod.txt"

STAGING_ALERT_EMAILS_JSON="$(cat "$EVID_DIR/staging_inputs.json")"
STAGING_AMI_ID="$(aws ssm get-parameter --region us-east-1 --name /fjcloud/staging/aws_ami_id --query Parameter.Value --output text)"
STAGING_CF_ZONE_ID="$(aws ssm get-parameter --region us-east-1 --name /fjcloud/staging/cloudflare_zone_id --query Parameter.Value --output text)"
STAGING_DOMAIN="staging.flapjack.foo"
CANARY_IMAGE_TAG="$(aws lambda get-function --region us-east-1 --function-name fjcloud-staging-customer-loop-canary --query Code.ImageUri --output text 2>/dev/null | sed "s/.*://")"
SUPPORT_IMAGE_TAG="$(aws lambda get-function --region us-east-1 --function-name fjcloud-staging-support-email-canary --query Code.ImageUri --output text 2>/dev/null | sed "s/.*://")"

cd ops/terraform/_shared
terraform init -reconfigure \
  -backend-config="bucket=fjcloud-tfstate-staging" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=fjcloud-tflock" > "$REPO/$EVID_DIR/terraform_init.txt" 2>&1

PLAN_ARGS=(
  -input=false
  -out="$REPO/$EVID_DIR/staging_plan.tfplan"
  -var="env=staging"
  -var="ami_id=$STAGING_AMI_ID"
  -var="domain=$STAGING_DOMAIN"
  -var="cloudflare_zone_id=$STAGING_CF_ZONE_ID"
  -var="alert_emails=$STAGING_ALERT_EMAILS_JSON"
)
if [ -n "$CANARY_IMAGE_TAG" ] && [ "$CANARY_IMAGE_TAG" != "pending-publication" ]; then
  PLAN_ARGS+=("-var=canary_image={tag=\"$CANARY_IMAGE_TAG\"}")
fi
if [ -n "$SUPPORT_IMAGE_TAG" ] && [ "$SUPPORT_IMAGE_TAG" != "latest" ]; then
  PLAN_ARGS+=("-var=support_email_canary_image_tag=$SUPPORT_IMAGE_TAG")
fi

{ printf "terraform plan"; for arg in "${PLAN_ARGS[@]}"; do printf " %q" "$arg"; done; printf "\n"; } > "$REPO/$EVID_DIR/staging_plan_command.txt"
terraform plan "${PLAN_ARGS[@]}" > "$REPO/$EVID_DIR/staging_plan_stdout.txt" 2>&1
terraform show -no-color "$REPO/$EVID_DIR/staging_plan.tfplan" > "$REPO/$EVID_DIR/staging_plan.txt"
terraform show -json "$REPO/$EVID_DIR/staging_plan.tfplan" \
  | jq '
      walk(
        if type == "object" and (.address? == "module.compute.tls_private_key.api_ssh") and (.values? | type == "object") then
          .values.private_key_openssh = "REDACTED"
          | .values.private_key_pem = "REDACTED"
          | .values.private_key_pem_pkcs8 = "REDACTED"
        elif type == "object" and (.address? == "module.data.aws_db_instance.main") and (.values? | type == "object") and (.values | has("password")) then
          .values.password = "REDACTED"
        elif type == "object" and (.address? | type == "string") and (.address | test("^module\\.data\\.aws_ssm_parameter\\.(db_password|database_url|internal_auth_token)$")) and (.values? | type == "object") and (.values | has("value")) then
          .values.value = "REDACTED"
        elif type == "object" and (.type? == "random_password") and (.values? | type == "object") and (.values | has("result")) then
          .values.result = "REDACTED"
        else
          .
        end
      )
    ' > "$REPO/$EVID_DIR/staging_plan.json"
cat > "$REPO/$EVID_DIR/staging_plan.tfplan" <<'EOF'
REDACTED: Terraform saved plans embed sensitive values such as generated private
keys and database credentials. Regenerate this plan locally from the saved plan
command if a binary replay artifact is required.
EOF

jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | .address' "$REPO/$EVID_DIR/staging_plan.json" | sort -u > "$REPO/$EVID_DIR/staging_changed_addresses.txt"
ALLOW_REGEX='^(terraform_data\.prod_alert_emails_guard|module\.monitoring\.aws_sns_topic_subscription\.email\[[^]]+\])$'
if [ -s "$REPO/$EVID_DIR/staging_changed_addresses.txt" ]; then
  grep -Ev "$ALLOW_REGEX" "$REPO/$EVID_DIR/staging_changed_addresses.txt" > "$REPO/$EVID_DIR/staging_offending_addresses.txt" || true
else
  : > "$REPO/$EVID_DIR/staging_offending_addresses.txt"
fi

{
  echo "allowed_pattern: $ALLOW_REGEX"
  echo "changed_addresses:"
  if [ -s "$REPO/$EVID_DIR/staging_changed_addresses.txt" ]; then cat "$REPO/$EVID_DIR/staging_changed_addresses.txt"; else echo "<empty>"; fi
  echo "offending_addresses:"
  if [ -s "$REPO/$EVID_DIR/staging_offending_addresses.txt" ]; then cat "$REPO/$EVID_DIR/staging_offending_addresses.txt"; echo "result: FAIL"; else echo "<none>"; echo "result: PASS"; fi
} > "$REPO/$EVID_DIR/staging_scope_check.txt"

if [ -s "$REPO/$EVID_DIR/staging_offending_addresses.txt" ]; then
  exit 2
fi
