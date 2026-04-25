#!/bin/bash
# fjcloud VM bootstrap script (baked into AMI, re-runnable)
#
# Reads instance metadata from IMDS (instance tags), fetches secrets from
# AWS SSM Parameter Store, writes env files, and starts services.
#
# Idempotent: safe to re-run. Will overwrite env files and restart services.
#
# IMDS tag access must be enabled at launch time (InstanceMetadataTags=enabled).
# This is handled by AwsVmProvisioner in the API server.
#
# Expected IMDS instance tags (set by AwsVmProvisioner):
#   customer_id  — UUID of the owning customer
#   node_id      — stable node identifier (e.g. "node-{uuid}")
#   environment  — deploy environment name (e.g. "staging" | "prod")
#   Name         — "fj-{hostname}" display name
#
# Expected SSM parameters:
#   /fjcloud/{environment}/database_url — PostgreSQL connection string
#   /fjcloud/{node_id}/api-key    — flapjack API key for this node

set -euo pipefail

LOG_TAG="fjcloud-bootstrap"
logger -t "$LOG_TAG" "starting bootstrap"

# --------------------------------------------------------------------------
# 1. Read instance metadata via IMDSv2
# --------------------------------------------------------------------------

# IMDSv2 token (6-hour TTL — AWS recommended default)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

logger -t "$LOG_TAG" "instance=$INSTANCE_ID region=$REGION"

# --------------------------------------------------------------------------
# 2. Read customer_id and node_id from IMDS instance tags
#
# Uses IMDS tag access (no API call, no IAM permissions needed, no eventual
# consistency race). Requires InstanceMetadataTags=enabled at launch time.
# --------------------------------------------------------------------------

CUSTOMER_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/tags/instance/customer_id)

NODE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/tags/instance/node_id)

if [ -z "${ENVIRONMENT:-}" ]; then
  ENVIRONMENT=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/tags/instance/environment || true)
fi

if [ -z "$CUSTOMER_ID" ] || [ "$CUSTOMER_ID" = "None" ] || [ "$CUSTOMER_ID" = "404 - Not Found" ]; then
  logger -t "$LOG_TAG" "ERROR: customer_id tag not found via IMDS"
  exit 1
fi
if [ -z "$NODE_ID" ] || [ "$NODE_ID" = "None" ] || [ "$NODE_ID" = "404 - Not Found" ]; then
  logger -t "$LOG_TAG" "ERROR: node_id tag not found via IMDS"
  exit 1
fi
if [ -z "${ENVIRONMENT:-}" ] || [ "$ENVIRONMENT" = "None" ] || [ "$ENVIRONMENT" = "404 - Not Found" ]; then
  logger -t "$LOG_TAG" "ERROR: environment not provided via env var or IMDS tag"
  exit 1
fi

logger -t "$LOG_TAG" "customer_id=$CUSTOMER_ID node_id=$NODE_ID environment=$ENVIRONMENT"

# --------------------------------------------------------------------------
# 3. Read secrets from AWS SSM Parameter Store
# --------------------------------------------------------------------------

get_ssm() {
  aws ssm get-parameter \
    --name "$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$REGION"
}

DB_URL=$(get_ssm "/fjcloud/$ENVIRONMENT/database_url")
API_KEY=$(get_ssm "/fjcloud/$NODE_ID/api-key")
DNS_DOMAIN=$(get_ssm "/fjcloud/$ENVIRONMENT/dns_domain")
INTERNAL_AUTH_TOKEN=$(get_ssm "/fjcloud/$ENVIRONMENT/internal_auth_token")

# --------------------------------------------------------------------------
# 4. Write environment files
# --------------------------------------------------------------------------

mkdir -p /etc/flapjack

# Flapjack engine env
cat > /etc/flapjack/env <<ENVEOF
DATABASE_URL=$DB_URL
FLAPJACK_API_KEY=$API_KEY
ENVEOF

# Metering agent env — var names match what the binary expects
# (see infra/metering-agent/src/config.rs)
cat > /etc/flapjack/metering-env <<ENVEOF
DATABASE_URL=$DB_URL
FLAPJACK_URL=http://$NODE_ID:7700
FLAPJACK_API_KEY=$API_KEY
INTERNAL_KEY=$INTERNAL_AUTH_TOKEN
TENANT_MAP_URL=https://api.$DNS_DOMAIN/internal/tenant-map
COLD_STORAGE_USAGE_URL=https://api.$DNS_DOMAIN/internal/cold-storage-usage
CUSTOMER_ID=$CUSTOMER_ID
NODE_ID=$NODE_ID
REGION=$REGION
ENVEOF

chmod 600 /etc/flapjack/env /etc/flapjack/metering-env
chown flapjack:flapjack /etc/flapjack/env /etc/flapjack/metering-env

# Override the baked systemd unit so current AMIs use the flapjack-owned env
# file contract without requiring an AMI rebuild before the next VM launch.
mkdir -p /etc/systemd/system/fj-metering-agent.service.d
cat > /etc/systemd/system/fj-metering-agent.service.d/runtime-env.conf <<'UNITEOF'
[Unit]
ConditionPathExists=/etc/flapjack/metering-env

[Service]
User=flapjack
Group=flapjack
EnvironmentFile=-/etc/flapjack/metering-env
UNITEOF

logger -t "$LOG_TAG" "env files written"

# --------------------------------------------------------------------------
# 5. Enable and start services
# --------------------------------------------------------------------------

systemctl daemon-reload
systemctl enable flapjack fj-metering-agent
systemctl start flapjack fj-metering-agent

logger -t "$LOG_TAG" "services started, bootstrap complete"
