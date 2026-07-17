#!/usr/bin/env bash
set -euo pipefail

label="${1:-}"
case "$label" in
  primary) ;;
  rerun) ;;
  *)
    echo "usage: $0 <primary|rerun>" >&2
    exit 1
    ;;
esac

REPO_ROOT="fjcloud_dev"
cd "$REPO_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$SCRIPT_DIR/runs/$label"
mkdir -p "$RUN_DIR"

source scripts/lib/env.sh
source scripts/lib/staging_db.sh

SECRET_FILE="${FJCLOUD_SECRET_FILE:-$PWD/.secret/.env.secret}"
# Ensure this evidence run uses repo secret-file AWS creds, not stale shell exports.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
load_layered_env_files "$SECRET_FILE"
: "${AWS_DEFAULT_REGION:=us-east-1}"
export AWS_DEFAULT_REGION

PROD_DATABASE_URL="$(aws ssm get-parameter --name /fjcloud/prod/database_url --with-decryption --query Parameter.Value --output text --region "$AWS_DEFAULT_REGION")"
STAGING_DATABASE_URL="$(aws ssm get-parameter --name /fjcloud/staging/database_url --with-decryption --query Parameter.Value --output text --region "$AWS_DEFAULT_REGION")"

[ -n "$PROD_DATABASE_URL" ] && [ "$PROD_DATABASE_URL" != "None" ] || { echo "missing prod db url" >&2; exit 1; }
[ -n "$STAGING_DATABASE_URL" ] && [ "$STAGING_DATABASE_URL" != "None" ] || { echo "missing staging db url" >&2; exit 1; }

STAGE1_DIR="$SCRIPT_DIR/../20260521T172106Z_stage1_inventory"
STAGE1_SUMMARY="$STAGE1_DIR/40_stage1_summary.json"
STAGE1_DISJOINT="$STAGE1_DIR/50_cohort_disjointness.txt"
[ -f "$STAGE1_SUMMARY" ] || { echo "missing stage1 summary" >&2; exit 1; }
[ -f "$STAGE1_DISJOINT" ] || { echo "missing stage1 disjointness proof" >&2; exit 1; }
grep -Fxq "cohort_disjointness=PASS" "$STAGE1_DISJOINT" || { echo "stage1 disjointness is not PASS" >&2; exit 1; }

BASE_SELECT="SELECT
  c.id::text AS customer_id,
  c.email,
  c.status,
  c.deleted_at,
  c.stripe_customer_id,
  ct.tenant_id,
  cd.id::text AS deployment_id,
  cd.status AS deployment_status,
  cd.provider_vm_id,
  cd.hostname,
  cd.flapjack_url,
  cd.ip_address,
  c.created_at
FROM customers c
LEFT JOIN customer_tenants ct ON ct.customer_id = c.id
LEFT JOIN customer_deployments cd ON cd.id = ct.deployment_id"
EXACT_FILTER_CONTRACT="email LIKE 'signup-paid-%@e2e.griddle.test'"
CREATED_AT_FLOOR_CONTRACT="customers.created_at >= '2026-05-14'"
BASE_WHERE="c.created_at >= '2026-05-14'::timestamptz"
EXACT_FILTER="c.email LIKE 'signup-paid-%@e2e.griddle.test'"
CANARY_FILTER="c.email LIKE 'canary+%@test.flapjack.foo'"
SUSPICIOUS_FILTER="(c.email LIKE '%test%' OR c.email LIKE '%example%') AND NOT (c.email LIKE 'signup-paid-%@e2e.griddle.test') AND NOT (c.email LIKE 'canary+%@test.flapjack.foo')"
ORDER_BY="ORDER BY c.created_at, c.id, ct.tenant_id, cd.id"

build_copy_sql() {
  local filter_sql="$1"
  printf "COPY (\n%s\nWHERE %s AND %s\n%s\n) TO STDOUT WITH CSV HEADER;" "$BASE_SELECT" "$BASE_WHERE" "$filter_sql" "$ORDER_BY"
}

run_sql_capture() {
  local db_url="$1"
  local ssm_param="$2"
  local sql="$3"
  local out_file="$4"
  local err_file="$5"
  DATABASE_URL_SSM_PARAM="$ssm_param"
  export DATABASE_URL_SSM_PARAM
  staging_db_run_sql "$db_url" "$sql" > "$out_file" 2> "$err_file"
}

run_sql_capture "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$(build_copy_sql "$EXACT_FILTER")" "$RUN_DIR/10_prod_exact_cleanup_rerun.csv" "$RUN_DIR/10_prod_exact_cleanup_rerun.stderr.txt"
run_sql_capture "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$(build_copy_sql "$EXACT_FILTER")" "$RUN_DIR/11_staging_exact_cleanup_rerun.csv" "$RUN_DIR/11_staging_exact_cleanup_rerun.stderr.txt"
run_sql_capture "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$(build_copy_sql "$SUSPICIOUS_FILTER")" "$RUN_DIR/20_prod_suspicious_inventory_rerun.csv" "$RUN_DIR/20_prod_suspicious_inventory_rerun.stderr.txt"
run_sql_capture "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$(build_copy_sql "$SUSPICIOUS_FILTER")" "$RUN_DIR/21_staging_suspicious_inventory_rerun.csv" "$RUN_DIR/21_staging_suspicious_inventory_rerun.stderr.txt"

ACTIVE_SQL="SELECT COUNT(*) FILTER (WHERE deleted_at IS NULL AND email LIKE 'signup-paid-%@e2e.griddle.test') AS active_exact_cleanup_customers FROM customers WHERE created_at >= '2026-05-14';"
run_sql_capture "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$ACTIVE_SQL" "$RUN_DIR/22_prod_active_exact_cleanup_count.txt" "$RUN_DIR/22_prod_active_exact_cleanup_count.stderr.txt"
run_sql_capture "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$ACTIVE_SQL" "$RUN_DIR/23_staging_active_exact_cleanup_count.txt" "$RUN_DIR/23_staging_active_exact_cleanup_count.stderr.txt"

python3 - "$RUN_DIR" "$STAGE1_SUMMARY" "$STAGE1_DIR" "$label" <<'PY'
import csv
import json
import pathlib
import re
import sys

run_dir = pathlib.Path(sys.argv[1])
stage1_summary = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
stage1_dir = pathlib.Path(sys.argv[3])
run_label = sys.argv[4]

def parse_count(path: pathlib.Path) -> int:
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("active_exact_cleanup_customers"):
            continue
        if line.startswith("-") or line.startswith("("):
            continue
        if re.fullmatch(r"\d+", line):
            return int(line)
    raise SystemExit(f"unable to parse count from {path}")

def read_csv(path: pathlib.Path):
    with path.open("r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))

def ids(rows, key="customer_id"):
    return sorted({(r.get(key) or "").strip() for r in rows if (r.get(key) or "").strip()})

prod_exact = read_csv(run_dir / "10_prod_exact_cleanup_rerun.csv")
staging_exact = read_csv(run_dir / "11_staging_exact_cleanup_rerun.csv")
prod_susp = read_csv(run_dir / "20_prod_suspicious_inventory_rerun.csv")
staging_susp = read_csv(run_dir / "21_staging_suspicious_inventory_rerun.csv")

stage1_prod_exact = read_csv(stage1_dir / "10_prod_exact_cleanup.csv")
stage1_staging_exact = read_csv(stage1_dir / "11_staging_exact_cleanup.csv")
stage1_prod_susp = read_csv(stage1_dir / "20_prod_suspicious_inventory.csv")
stage1_staging_susp = read_csv(stage1_dir / "21_staging_suspicious_inventory.csv")
stage1_prod_canary = read_csv(stage1_dir / "30_prod_canary_control.csv")
stage1_staging_canary = read_csv(stage1_dir / "31_staging_canary_control.csv")

stage1_exact_sets = {
    "prod": set(ids(stage1_prod_exact)),
    "staging": set(ids(stage1_staging_exact)),
}
run_exact_sets = {
    "prod": set(ids(prod_exact)),
    "staging": set(ids(staging_exact)),
}

for env in ("prod", "staging"):
    extra = sorted(run_exact_sets[env] - stage1_exact_sets[env])
    if extra:
        raise SystemExit(f"stage6 exact rerun introduced out-of-contract {env} customers: {extra}")

stage1_disjoint_guard = {
    "prod": set(ids(stage1_prod_exact)) | set(ids(stage1_prod_canary)),
    "staging": set(ids(stage1_staging_exact)) | set(ids(stage1_staging_canary)),
}
run_susp_sets = {
    "prod": set(ids(prod_susp)),
    "staging": set(ids(staging_susp)),
}

for env in ("prod", "staging"):
    overlap = sorted(run_susp_sets[env] & stage1_disjoint_guard[env])
    if overlap:
        raise SystemExit(f"stage6 suspicious rerun overlaps stage1 exact/canary set for {env}: {overlap}")

prod_active = parse_count(run_dir / "22_prod_active_exact_cleanup_count.txt")
staging_active = parse_count(run_dir / "23_staging_active_exact_cleanup_count.txt")

summary = {
    "run_label": run_label,
    "stage1_contract_summary": str(stage1_dir / "40_stage1_summary.json"),
    "stage1_summary_generated_at_utc": stage1_summary.get("generated_at_utc"),
    "counts": {
        "prod": {
            "active_exact_cleanup_customers": prod_active,
            "exact_rows": len(prod_exact),
            "suspicious_rows": len(prod_susp),
        },
        "staging": {
            "active_exact_cleanup_customers": staging_active,
            "exact_rows": len(staging_exact),
            "suspicious_rows": len(staging_susp),
        },
    },
    "customer_ids": {
        "prod": {
            "exact": ids(prod_exact),
            "suspicious": ids(prod_susp),
            "stage1_suspicious": ids(stage1_prod_susp),
        },
        "staging": {
            "exact": ids(staging_exact),
            "suspicious": ids(staging_susp),
            "stage1_suspicious": ids(stage1_staging_susp),
        },
    },
}
(run_dir / "40_run_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

if prod_active != 0 or staging_active != 0:
    raise SystemExit(f"active_exact_cleanup_customers must be zero (prod={prod_active}, staging={staging_active})")
PY

prod_active_count="$(python3 - "$RUN_DIR/22_prod_active_exact_cleanup_count.txt" <<'PY'
import pathlib,re,sys
for raw_line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("active_exact_cleanup_customers"):
        continue
    if line.startswith("-") or line.startswith("("):
        continue
    if re.fullmatch(r"\d+", line):
        print(int(line))
        break
else:
    print(-1)
PY
)"
staging_active_count="$(python3 - "$RUN_DIR/23_staging_active_exact_cleanup_count.txt" <<'PY'
import pathlib,re,sys
for raw_line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("active_exact_cleanup_customers"):
        continue
    if line.startswith("-") or line.startswith("("):
        continue
    if re.fullmatch(r"\d+", line):
        print(int(line))
        break
else:
    print(-1)
PY
)"
if [ "$prod_active_count" -ne 0 ] || [ "$staging_active_count" -ne 0 ]; then
  echo "active exact cleanup customers non-zero: prod=$prod_active_count staging=$staging_active_count" >&2
  exit 1
fi

echo "stage6_run=${label} prod_active_exact_cleanup_customers=${prod_active_count} staging_active_exact_cleanup_customers=${staging_active_count}"
