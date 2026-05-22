#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <evidence-dir>" >&2
  exit 2
fi

EVID_DIR="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
cd "$REPO_ROOT"

source scripts/lib/env.sh
source scripts/lib/staging_db.sh

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_REGION
load_layered_env_files "${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
export DATABASE_URL_SSM_PARAM="${DATABASE_URL_SSM_PARAM:-/fjcloud/prod/database_url}"

DATABASE_URL="${DATABASE_URL:-}"
if [ -z "$DATABASE_URL" ]; then
  DATABASE_URL="$(aws ssm get-parameter --name "$DATABASE_URL_SSM_PARAM" --with-decryption --query 'Parameter.Value' --output text)"
fi
if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: DATABASE_URL is empty after SSM lookup" >&2
  exit 2
fi

run_export() {
  local output_csv="$1"
  local sql="$2"
  staging_db_run_sql "$DATABASE_URL" "$sql" > "$EVID_DIR/$output_csv"
}

SQL_vm_inventory_status_counts=$(cat <<'SQL'
COPY (
  SELECT status, COUNT(*) AS count
  FROM vm_inventory
  GROUP BY status
  ORDER BY status
) TO STDOUT WITH CSV HEADER;
SQL
)
run_export "vm_inventory_status_counts.csv" "$SQL_vm_inventory_status_counts"

SQL_customer_deployments_status_counts=$(cat <<'SQL'
COPY (
  SELECT status, COUNT(*) AS count
  FROM customer_deployments
  GROUP BY status
  ORDER BY status
) TO STDOUT WITH CSV HEADER;
SQL
)
run_export "customer_deployments_status_counts.csv" "$SQL_customer_deployments_status_counts"

SQL_provisioning_age_distribution=$(cat <<'SQL'
COPY (
  SELECT
    CASE
      WHEN created_at >= (NOW() - INTERVAL '15 minutes') THEN 'lt_15m'
      WHEN created_at >= (NOW() - INTERVAL '1 hour') THEN '15m_to_1h'
      WHEN created_at >= (NOW() - INTERVAL '6 hours') THEN '1h_to_6h'
      WHEN created_at >= (NOW() - INTERVAL '24 hours') THEN '6h_to_24h'
      ELSE 'gte_24h'
    END AS age_bucket,
    COUNT(*) AS count
  FROM customer_deployments
  WHERE status = 'provisioning'
  GROUP BY age_bucket
  ORDER BY age_bucket
) TO STDOUT WITH CSV HEADER;
SQL
)
run_export "provisioning_age_distribution.csv" "$SQL_provisioning_age_distribution"

SQL_provisioning_rows_detailed=$(cat <<'SQL'
COPY (
  SELECT
    cd.id::text AS deployment_id,
    cd.customer_id::text AS customer_id,
    cd.status,
    cd.vm_provider,
    cd.provider_vm_id,
    cd.hostname,
    cd.flapjack_url,
    cd.created_at,
    ct.tenant_id,
    ct.vm_id::text AS tenant_vm_id,
    vi.id::text AS inventory_vm_id,
    vi.status AS inventory_status,
    vi.updated_at AS inventory_updated_at
  FROM customer_deployments cd
  LEFT JOIN customer_tenants ct ON ct.deployment_id = cd.id
  LEFT JOIN vm_inventory vi ON vi.id::text = cd.provider_vm_id
  WHERE cd.status = 'provisioning'
  ORDER BY cd.created_at ASC
) TO STDOUT WITH CSV HEADER;
SQL
)
run_export "provisioning_rows_detailed.csv" "$SQL_provisioning_rows_detailed"

SQL_provisioning_by_customer_cohort=$(cat <<'SQL'
COPY (
  SELECT
    CASE
      WHEN cd.created_at >= (NOW() - INTERVAL '7 days') THEN 'created_last_7d'
      WHEN cd.created_at >= (NOW() - INTERVAL '30 days') THEN 'created_8d_to_30d'
      ELSE 'created_gt_30d'
    END AS customer_cohort,
    COUNT(*) AS provisioning_count,
    COUNT(DISTINCT cd.customer_id) AS customer_count
  FROM customer_deployments cd
  WHERE cd.status = 'provisioning'
  GROUP BY customer_cohort
  ORDER BY customer_cohort
) TO STDOUT WITH CSV HEADER;
SQL
)
run_export "provisioning_by_customer_cohort.csv" "$SQL_provisioning_by_customer_cohort"

SQL_billing_accuracy_impact=$(cat <<'SQL'
COPY (
  SELECT
    COUNT(*) FILTER (WHERE cd.status = 'provisioning') AS provisioning_rows,
    COUNT(*) FILTER (
      WHERE cd.status = 'provisioning'
        AND cd.provider_vm_id LIKE 'provisioning-lock:%'
    ) AS provisioning_lock_rows,
    COUNT(*) FILTER (
      WHERE cd.status = 'provisioning'
        AND cd.provider_vm_id LIKE 'aws:%'
    ) AS provisioning_rows_with_aws_provider_id,
    COUNT(*) FILTER (
      WHERE cd.status = 'provisioning'
        AND vi.id IS NOT NULL
    ) AS provisioning_rows_linked_to_inventory,
    COUNT(*) FILTER (
      WHERE cd.status = 'provisioning'
        AND vi.id IS NULL
    ) AS provisioning_rows_missing_inventory_link
  FROM customer_deployments cd
  LEFT JOIN vm_inventory vi ON vi.id::text = cd.provider_vm_id
) TO STDOUT WITH CSV HEADER;
SQL
)
run_export "billing_accuracy_impact.csv" "$SQL_billing_accuracy_impact"
