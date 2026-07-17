set -euo pipefail
cd fjcloud_dev
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_REGION
export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$PWD/.secret/.env.secret}"
source scripts/validate_full_vm_lifecycle_prod.sh
load_orchestration_env

EVID_DIR="docs/runbooks/evidence/fleet-recovery/20260520T211417Z_baseline"

# 00a_secret_twin_check.txt
python3 - <<'PY' > "$EVID_DIR/00a_secret_twin_check.txt" 2> "$EVID_DIR/00a_secret_twin_check.stderr.txt"
from pathlib import Path
import os
import re

secret_file = Path(os.environ["FJCLOUD_SECRET_FILE"]).resolve()
content = secret_file.read_text(encoding="utf-8")
print(f"secret_file={secret_file}")
for line_no, line in enumerate(content.splitlines(), start=1):
    if line.startswith("AWS_ACCESS_KEY_ID="):
        print(f"present_key={line_no}:AWS_ACCESS_KEY_ID")
    if line.startswith("AWS_SECRET_ACCESS_KEY="):
        print(f"present_key={line_no}:AWS_SECRET_ACCESS_KEY")
has_twin = bool(
    re.search(r"^AWS_ACCESS_KEY_ID_(NEW|ROTATED)=", content, flags=re.MULTILINE)
)
print(f"aws_access_key_has_twin={'true' if has_twin else 'false'}")
PY

# 00_aws_identity.json
aws sts get-caller-identity > "$EVID_DIR/00_aws_identity.json" 2> "$EVID_DIR/00_aws_identity.stderr.txt"

# 01_staging_ci.json
gh run list -R gridl-infra-staging/fjcloud --workflow=CI --limit 1 --json conclusion,headSha,createdAt > "$EVID_DIR/01_staging_ci.json" 2> "$EVID_DIR/01_staging_ci.stderr.txt"

# 02_prod_ci.json
gh run list -R gridl-infra-prod/fjcloud --workflow=CI --limit 1 --json conclusion,headSha,createdAt > "$EVID_DIR/02_prod_ci.json" 2> "$EVID_DIR/02_prod_ci.stderr.txt"

# 03_prod_runtime_params.json
aws ssm get-parameters \
  --names /fjcloud/prod/database_url /fjcloud/prod/admin_key /fjcloud/prod/aws_ami_id /fjcloud/prod/cloudflare_zone_id \
  --with-decryption \
  --query 'Parameters[].{Name:Name,Version:Version}' \
  --output json > "$EVID_DIR/03_prod_runtime_params.json" 2> "$EVID_DIR/03_prod_runtime_params.stderr.txt"

# 03_prod_runtime_params_validate.stdout.txt
python3 - "$EVID_DIR/03_prod_runtime_params.json" <<'PY' > "$EVID_DIR/03_prod_runtime_params_validate.stdout.txt" 2> "$EVID_DIR/03_prod_runtime_params_validate.stderr.txt"
import json
import sys

expected = {
    "/fjcloud/prod/database_url",
    "/fjcloud/prod/admin_key",
    "/fjcloud/prod/aws_ami_id",
    "/fjcloud/prod/cloudflare_zone_id",
}
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
found = {entry["Name"] for entry in payload}
missing = sorted(expected - found)
if missing:
    raise SystemExit(f"missing required prod runtime params: {', '.join(missing)}")
print("validated required prod runtime parameter names")
PY

# 03b_database_url_lookup.stdout.txt
aws ssm get-parameter --name /fjcloud/prod/database_url --with-decryption --query 'Parameter.Value' --output text > "$EVID_DIR/03b_database_url_lookup.stdout.txt" 2> "$EVID_DIR/03b_database_url_lookup.stderr.txt"
export DATABASE_URL_SSM_PARAM=/fjcloud/prod/database_url
export DATABASE_URL="$(cat "$EVID_DIR/03b_database_url_lookup.stdout.txt")"

# 10_admin_fleet.json
curl -fsS -H "x-admin-key: ${ADMIN_KEY}" "${API_URL%/}/admin/fleet" > "$EVID_DIR/10_admin_fleet.json" 2> "$EVID_DIR/10_admin_fleet.stderr.txt"

# 10_admin_fleet_validate.stdout.txt
python3 - "$EVID_DIR/10_admin_fleet.json" <<'PY' > "$EVID_DIR/10_admin_fleet_validate.stdout.txt" 2> "$EVID_DIR/10_admin_fleet_validate.stderr.txt"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    json.load(fh)
print("validated admin fleet JSON parse")
PY

# 11_ec2_instances.json
aws ec2 describe-instances \
  --filters Name=tag:managed-by,Values=fjcloud Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value,PrivateIp:PrivateIpAddress,LaunchTime:LaunchTime}' \
  --output json > "$EVID_DIR/11_ec2_instances.json" 2> "$EVID_DIR/11_ec2_instances.stderr.txt"

# 20_vm_inventory.sql.txt
bash -lc 'source scripts/lib/staging_db.sh; staging_db_run_sql "$DATABASE_URL" "SELECT id::text, provider, status, region, hostname, flapjack_url, capacity, current_load, updated_at FROM vm_inventory ORDER BY updated_at DESC LIMIT 200;"' > "$EVID_DIR/20_vm_inventory.sql.txt" 2> "$EVID_DIR/20_vm_inventory.stderr.txt"

# 21_customer_deployments_by_status.sql.txt
bash -lc 'source scripts/lib/staging_db.sh; staging_db_run_sql "$DATABASE_URL" "SELECT status, COUNT(*) FROM customer_deployments GROUP BY status ORDER BY status;"' > "$EVID_DIR/21_customer_deployments_by_status.sql.txt" 2> "$EVID_DIR/21_customer_deployments_by_status.stderr.txt"

# 22_customer_deployments_provisioning.sql.txt
bash -lc 'source scripts/lib/staging_db.sh; staging_db_run_sql "$DATABASE_URL" "SELECT id::text, customer_id::text, provider_vm_id, status, created_at FROM customer_deployments WHERE status = 'provisioning' ORDER BY created_at DESC LIMIT 200;"' > "$EVID_DIR/22_customer_deployments_provisioning.sql.txt" 2> "$EVID_DIR/22_customer_deployments_provisioning.stderr.txt"

# 30_run_a_red.txt
bash scripts/validate_full_vm_lifecycle_prod.sh run-a 2>&1 | tee "$EVID_DIR/30_run_a_red.txt" || true
grep -q "step 'create_index' failed:" "$EVID_DIR/30_run_a_red.txt"
