#!/usr/bin/env bash
# migrate.sh — Run SQL migrations on EC2 instance
# Called by deploy.sh via SSM or manually. Runs ON the EC2 instance.
#
# Usage: migrate.sh <env>
#
# Fetches DATABASE_URL from SSM, runs sqlx migrations idempotently.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: migrate.sh <env>"
  echo "  env: staging | prod"
  exit 1
fi

ENV="$1"
MIGRATIONS_DIR="/opt/fjcloud/migrations"

if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
  echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
  exit 1
fi

echo "==> Fetching DATABASE_URL from SSM /fjcloud/${ENV}/database_url"

DATABASE_URL=$(aws ssm get-parameter \
  --name "/fjcloud/${ENV}/database_url" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region us-east-1)

if [[ -z "$DATABASE_URL" ]]; then
  echo "ERROR: DATABASE_URL is empty — check SSM parameter /fjcloud/${ENV}/database_url"
  exit 1
fi

export DATABASE_URL

echo "==> Running sqlx migrate run --source ${MIGRATIONS_DIR}"

sqlx migrate run --source "$MIGRATIONS_DIR" --database-url "$DATABASE_URL"

echo "==> Migrations complete"
