set -euo pipefail
source /etc/fjcloud/env
if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL is empty on staging host" >&2
  exit 1
fi
RESTORED_ENDPOINT="fjcloud-staging-restore-20260526003636.cabwlew6jcjl.us-east-1.rds.amazonaws.com"
LIVE_URL="$DATABASE_URL"
RESTORED_URL="$(python3 - "$DATABASE_URL" "$RESTORED_ENDPOINT" <<'PY2'
from urllib.parse import urlsplit, urlunsplit
import sys
url=sys.argv[1]
endpoint=sys.argv[2]
parts=urlsplit(url)
userinfo = ""
if "@" in parts.netloc:
    userinfo, _ = parts.netloc.rsplit("@",1)
new_netloc = f"{userinfo}@{endpoint}" if userinfo else endpoint
print(urlunsplit((parts.scheme,new_netloc,parts.path,parts.query,parts.fragment)))
PY2
)"
LIVE_HOST="$(python3 - "$DATABASE_URL" <<'PY2'
from urllib.parse import urlsplit
import sys
print((urlsplit(sys.argv[1]).hostname) or "")
PY2
)"
echo "live_host=${LIVE_HOST}"
echo "restored_host=${RESTORED_ENDPOINT}"
echo "=== restored_sql_results_begin ==="
psql "$RESTORED_URL" -v ON_ERROR_STOP=1 -tA <<'SQL2'
SELECT COUNT(*) AS customers_total FROM customers;
SELECT COUNT(*) AS customer_tenants_total FROM customer_tenants;
SELECT COUNT(*) AS invoices_last_7d FROM invoices WHERE created_at > now() - interval '7 days';
SELECT COUNT(*) AS deployments_running FROM customer_deployments WHERE status = 'running';
SELECT COUNT(*) AS usage_records_last_1d FROM usage_records WHERE recorded_at > now() - interval '1 day';
SELECT COUNT(*) AS migrations_total FROM _sqlx_migrations;
SELECT MAX(version) AS migrations_max_version FROM _sqlx_migrations;
SQL2
echo "=== restored_sql_results_end ==="
echo "=== live_migrations_begin ==="
psql "$LIVE_URL" -v ON_ERROR_STOP=1 -tA <<'SQL2'
SELECT COUNT(*) AS migrations_total FROM _sqlx_migrations;
SELECT MAX(version) AS migrations_max_version FROM _sqlx_migrations;
SQL2
echo "=== live_migrations_end ==="
