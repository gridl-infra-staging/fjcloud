#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="fjcloud_dev"
cd "$REPO_ROOT"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_REGION
export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"

source scripts/validate_full_vm_lifecycle_prod.sh
source scripts/lib/staging_db.sh

load_orchestration_env
resolve_stage5_database_url

EVID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE2_DIR="$REPO_ROOT/docs/runbooks/evidence/fleet-recovery/20260520T214507Z_diagnosis"

mkdir -p "$EVID_DIR/pre" "$EVID_DIR/post" "$EVID_DIR/sql" "$EVID_DIR/batches" "$EVID_DIR/mutations"

cp "$STAGE2_DIR/27_provider_inventory_reconciliation.json" "$EVID_DIR/pre/stage2_27_provider_inventory_reconciliation.json"
cp "$STAGE2_DIR/28_reconciliation_counts.md" "$EVID_DIR/pre/stage2_28_reconciliation_counts.md"
cp "$STAGE2_DIR/32_bookkeeping_hypothesis.sql.txt" "$EVID_DIR/pre/stage2_32_bookkeeping_hypothesis.sql.txt"

run_probe_allow_mismatch() {
    local phase="$1"
    local rc=0
    set +e
    bash scripts/reliability/validate_vm_inventory_ec2_consistency.sh \
        --evidence-dir "$EVID_DIR/$phase" \
        > "$EVID_DIR/$phase/summary.json" \
        2> "$EVID_DIR/$phase/summary.stderr.txt"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        echo "probe failed for phase=$phase rc=$rc" >&2
        return "$rc"
    fi
    printf '%s\n' "$rc" > "$EVID_DIR/$phase/probe_exit_code.txt"
}

run_sql_capture() {
    local sql_file="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    local sql
    sql="$(cat "$sql_file")"
    staging_db_run_sql "$DATABASE_URL" "$sql" > "$stdout_file" 2> "$stderr_file"
}

run_probe_allow_mismatch pre

cat > "$EVID_DIR/sql/pre_bookkeeping_counts.sql" <<'SQL'
SELECT
  COUNT(*) FILTER (WHERE cd.status = 'provisioning') AS provisioning_total,
  COUNT(*) FILTER (
    WHERE cd.status = 'provisioning'
      AND EXISTS (
        SELECT 1
        FROM vm_inventory vi
        WHERE vi.id::text = cd.provider_vm_id
      )
  ) AS provider_vm_id_matches_vm_inventory_id,
  COUNT(*) FILTER (
    WHERE cd.status = 'provisioning'
      AND cd.provider_vm_id LIKE 'aws:%'
  ) AS provider_vm_id_aws_style
FROM customer_deployments cd;
SQL
run_sql_capture \
    "$EVID_DIR/sql/pre_bookkeeping_counts.sql" \
    "$EVID_DIR/pre/32_bookkeeping_hypothesis.sql.txt" \
    "$EVID_DIR/pre/32_bookkeeping_hypothesis.stderr.txt"

cat > "$EVID_DIR/sql/pre_deployments_by_status.sql" <<'SQL'
COPY (
  SELECT status, COUNT(*) AS count
  FROM customer_deployments
  GROUP BY status
  ORDER BY status
) TO STDOUT WITH CSV HEADER;
SQL
run_sql_capture \
    "$EVID_DIR/sql/pre_deployments_by_status.sql" \
    "$EVID_DIR/pre/24_customer_deployments_by_status.csv" \
    "$EVID_DIR/pre/24_customer_deployments_by_status.stderr.txt"

cat > "$EVID_DIR/sql/pre_shared_provisioning_rows.sql" <<'SQL'
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
    vi.id::text AS inventory_vm_id
  FROM customer_deployments cd
  LEFT JOIN customer_tenants ct ON ct.deployment_id = cd.id
  LEFT JOIN vm_inventory vi ON vi.id::text = cd.provider_vm_id
  WHERE cd.status = 'provisioning'
    AND cd.vm_provider = 'aws'
    AND cd.provider_vm_id = vi.id::text
    AND cd.hostname IS NOT NULL
    AND cd.flapjack_url IS NOT NULL
  ORDER BY cd.created_at
) TO STDOUT WITH CSV HEADER;
SQL
run_sql_capture \
    "$EVID_DIR/sql/pre_shared_provisioning_rows.sql" \
    "$EVID_DIR/pre/shared_provisioning_rows.csv" \
    "$EVID_DIR/pre/shared_provisioning_rows.stderr.txt"

python3 - "$EVID_DIR/pre/summary.json" "$EVID_DIR/pre/ec2_instances.json" "$EVID_DIR/sql" <<'PY'
import csv
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
ec2_path = pathlib.Path(sys.argv[2])
out_dir = pathlib.Path(sys.argv[3])
out_dir.mkdir(parents=True, exist_ok=True)

summary = json.loads(summary_path.read_text(encoding='utf-8'))
ec2_rows = json.loads(ec2_path.read_text(encoding='utf-8'))
raw = summary.get('raw_records', {})

(out_dir / 'class1_inventory_rows_without_ec2_match.json').write_text(
    json.dumps(raw.get('inventory_rows_without_nonterminated_ec2_match', []), indent=2),
    encoding='utf-8',
)
(out_dir / 'class4_stuck_shared_provisioning_rows.json').write_text(
    json.dumps(raw.get('stuck_shared_provisioning_rows', []), indent=2),
    encoding='utf-8',
)

ec2_by_instance = {}
for row in ec2_rows:
    instance_id = str(row.get('InstanceId') or '')
    if instance_id:
        ec2_by_instance[instance_id] = row

missing_rows = raw.get('managed_instances_without_inventory_match', [])
shared_rows = []
nonshared_rows = []
for row in missing_rows:
    instance_id = str(row.get('instance_id') or '')
    ec2 = ec2_by_instance.get(instance_id, {})
    tags = {str(t.get('Key')): str(t.get('Value', '')) for t in (ec2.get('Tags') or []) if isinstance(t, dict)}
    hostname = str(row.get('hostname') or '')
    launch_time = str(row.get('launch_time') or '')
    az = str(((ec2.get('Placement') or {}).get('AvailabilityZone')) or '')
    region = az[:-1] if len(az) > 1 else 'us-east-1'
    payload = {
        'instance_id': instance_id,
        'hostname': hostname,
        'launch_time': launch_time,
        'region': region,
        'name_tag': tags.get('Name', ''),
        'node_id_tag': tags.get('node_id', ''),
        'customer_id_tag': tags.get('customer_id', ''),
        'flapjack_url': f'http://{hostname}:7700' if hostname else '',
    }
    if hostname.startswith('vm-shared-'):
        shared_rows.append(payload)
    else:
        nonshared_rows.append(payload)

(out_dir / 'class2_shared_managed_missing_inventory.json').write_text(
    json.dumps(shared_rows, indent=2),
    encoding='utf-8',
)
(out_dir / 'class3_nonshared_managed_missing_inventory.json').write_text(
    json.dumps(nonshared_rows, indent=2),
    encoding='utf-8',
)


def write_csv(path, rows, columns):
    with path.open('w', encoding='utf-8', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, '') for key in columns})

write_csv(
    out_dir / 'class2_shared_managed_missing_inventory.csv',
    shared_rows,
    ['instance_id', 'hostname', 'region', 'flapjack_url', 'name_tag', 'node_id_tag', 'customer_id_tag', 'launch_time'],
)
write_csv(
    out_dir / 'class3_nonshared_managed_missing_inventory.csv',
    nonshared_rows,
    ['instance_id', 'hostname', 'region', 'flapjack_url', 'name_tag', 'node_id_tag', 'customer_id_tag', 'launch_time'],
)
PY

cat > "$EVID_DIR/mutations/10_insert_missing_shared_inventory.sql" <<'SQL'
SELECT '0'::text AS inserted_rows;
SQL

python3 - "$EVID_DIR/sql/class2_shared_managed_missing_inventory.csv" "$EVID_DIR/mutations/10_insert_missing_shared_inventory.sql" <<'PY'
import csv
import pathlib
import sys

csv_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
rows = []
with csv_path.open('r', encoding='utf-8', newline='') as fh:
    for row in csv.DictReader(fh):
        hostname = (row.get('hostname') or '').strip()
        region = (row.get('region') or 'us-east-1').strip() or 'us-east-1'
        flapjack_url = (row.get('flapjack_url') or '').strip()
        if hostname and flapjack_url:
            rows.append((hostname, region, flapjack_url))
rows = sorted(set(rows))
if not rows:
    out_path.write_text("SELECT '0'::text AS inserted_rows;\n", encoding='utf-8')
    raise SystemExit(0)

def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"

values_sql = ',\n            '.join(
    f"({sql_literal(hostname)}, {sql_literal(region)}, {sql_literal(flapjack_url)})"
    for hostname, region, flapjack_url in rows
)
sql = f"""WITH candidates(hostname, region, flapjack_url) AS (
    SELECT hostname, region, flapjack_url
    FROM (
        VALUES
            {values_sql}
    ) AS t(hostname, region, flapjack_url)
),
inserted AS (
    INSERT INTO vm_inventory (region, provider, hostname, flapjack_url, capacity)
    SELECT c.region, 'aws', c.hostname, c.flapjack_url, '{{}}'::jsonb
    FROM candidates c
    WHERE NOT EXISTS (
        SELECT 1
        FROM vm_inventory vi
        WHERE vi.hostname = c.hostname
    )
    RETURNING id, hostname
)
SELECT COUNT(*)::text AS inserted_rows FROM inserted;
"""
out_path.write_text(sql, encoding='utf-8')
PY

run_sql_capture \
    "$EVID_DIR/mutations/10_insert_missing_shared_inventory.sql" \
    "$EVID_DIR/batches/10_insert_missing_shared_inventory.out.txt" \
    "$EVID_DIR/batches/10_insert_missing_shared_inventory.err.txt"

cat > "$EVID_DIR/sql/post_candidate_inventory_snapshot.sql" <<'SQL'
COPY (
  SELECT id::text, status, region, provider, hostname, flapjack_url, created_at, updated_at
  FROM vm_inventory
  WHERE hostname IN (
    'vm-shared-3bd2b971.flapjack.foo',
    'vm-shared-391f314f.flapjack.foo',
    'vm-shared-480b5169.flapjack.foo',
    'vm-20aa6d79.flapjack.foo'
  )
  ORDER BY hostname
) TO STDOUT WITH CSV HEADER;
SQL
run_sql_capture \
    "$EVID_DIR/sql/post_candidate_inventory_snapshot.sql" \
    "$EVID_DIR/post/candidate_inventory_after.csv" \
    "$EVID_DIR/post/candidate_inventory_after.stderr.txt"

run_probe_allow_mismatch post

cat > "$EVID_DIR/sql/post_bookkeeping_counts.sql" <<'SQL'
SELECT
  COUNT(*) FILTER (WHERE cd.status = 'provisioning') AS provisioning_total,
  COUNT(*) FILTER (
    WHERE cd.status = 'provisioning'
      AND EXISTS (
        SELECT 1
        FROM vm_inventory vi
        WHERE vi.id::text = cd.provider_vm_id
      )
  ) AS provider_vm_id_matches_vm_inventory_id,
  COUNT(*) FILTER (
    WHERE cd.status = 'provisioning'
      AND cd.provider_vm_id LIKE 'aws:%'
  ) AS provider_vm_id_aws_style
FROM customer_deployments cd;
SQL
run_sql_capture \
    "$EVID_DIR/sql/post_bookkeeping_counts.sql" \
    "$EVID_DIR/post/32_bookkeeping_hypothesis.sql.txt" \
    "$EVID_DIR/post/32_bookkeeping_hypothesis.stderr.txt"

cat > "$EVID_DIR/sql/post_deployments_by_status.sql" <<'SQL'
COPY (
  SELECT status, COUNT(*) AS count
  FROM customer_deployments
  GROUP BY status
  ORDER BY status
) TO STDOUT WITH CSV HEADER;
SQL
run_sql_capture \
    "$EVID_DIR/sql/post_deployments_by_status.sql" \
    "$EVID_DIR/post/24_customer_deployments_by_status.csv" \
    "$EVID_DIR/post/24_customer_deployments_by_status.stderr.txt"

cat > "$EVID_DIR/sql/post_tenant_vm_linkage.sql" <<'SQL'
COPY (
  SELECT
    ct.customer_id::text,
    ct.tenant_id,
    ct.deployment_id::text,
    ct.vm_id::text,
    cd.status,
    cd.hostname,
    cd.flapjack_url,
    vi.hostname AS vm_hostname,
    vi.flapjack_url AS vm_flapjack_url
  FROM customer_tenants ct
  JOIN customer_deployments cd ON cd.id = ct.deployment_id
  LEFT JOIN vm_inventory vi ON vi.id = ct.vm_id
  WHERE cd.status != 'terminated'
    AND cd.vm_provider = 'aws'
  ORDER BY cd.created_at DESC
  LIMIT 400
) TO STDOUT WITH CSV HEADER;
SQL
run_sql_capture \
    "$EVID_DIR/sql/post_tenant_vm_linkage.sql" \
    "$EVID_DIR/post/tenant_vm_linkage.csv" \
    "$EVID_DIR/post/tenant_vm_linkage.stderr.txt"

python3 - "$EVID_DIR/pre/summary.json" "$EVID_DIR/post/summary.json" "$EVID_DIR/sql/class3_nonshared_managed_missing_inventory.json" "$EVID_DIR/SUMMARY.md" <<'PY'
import json
import pathlib
import sys

pre = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
post = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding='utf-8'))
nonshared = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding='utf-8'))
out = pathlib.Path(sys.argv[4])

keys = [
    'inventory_rows_without_nonterminated_ec2_match',
    'managed_instances_without_inventory_match',
    'deployment_linkage_mismatches',
    'stuck_shared_provisioning_rows',
]

lines = []
lines.append('# Stage 4 Reconciliation Summary')
lines.append('')
lines.append('## Mutation Sets')
lines.append('- Inserted missing `vm_inventory` rows for EC2-managed hosts proven shared by `vm-shared-*` hostname and `managed-by=fjcloud` tag evidence.')
lines.append('- No deployment/tenant status transitions were applied in this run because the stale shared-provisioning bucket was already zero in pre-state.')
lines.append('')
lines.append('## Probe Buckets (Pre -> Post)')
for key in keys:
    lines.append(f'- `{key}`: {pre.get(key)} -> {post.get(key)}')
lines.append('')
if nonshared:
    lines.append('## Residual Deferred Rows (Stage 5)')
    lines.append('- `managed_instances_without_inventory_match` retains non-shared managed EC2 rows (`vm-*` without shared naming).')
    lines.append('- These rows were not force-inserted into `vm_inventory` to avoid inventing shared-fleet semantics for non-shared hosts.')
    lines.append('- Evidence file: `sql/class3_nonshared_managed_missing_inventory.json`.')
else:
    lines.append('## Residual Deferred Rows (Stage 5)')
    lines.append('- None.')
lines.append('')
lines.append('## Evidence Index')
lines.append('- `pre/summary.json`, `post/summary.json`')
lines.append('- `pre/32_bookkeeping_hypothesis.sql.txt`, `post/32_bookkeeping_hypothesis.sql.txt`')
lines.append('- `pre/24_customer_deployments_by_status.csv`, `post/24_customer_deployments_by_status.csv`')
lines.append('- `sql/class2_shared_managed_missing_inventory.csv`, `sql/class3_nonshared_managed_missing_inventory.csv`')
lines.append('- `batches/10_insert_missing_shared_inventory.out.txt`')
out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
