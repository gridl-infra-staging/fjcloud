#!/usr/bin/env bash
# probe_rollup.sh — usage_daily rollup freshness probe.
# Mirrors scripts/lib/metering_checks.sh::check_rollup_current (column
# aggregated_at, 48h owner-window). Sources DATABASE_URL from the staging API
# systemd EnvironmentFile via the SSM seam, since this clone has no direct
# PRODUCTION_DB_DSN/DATABASE_URL exported.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

remote='set -e
set -a
sudo cat /etc/fjcloud/env > /tmp/_rollup_env
source /tmp/_rollup_env
set +a
psql "$DATABASE_URL" -At -c "SELECT COUNT(*) FROM usage_daily WHERE aggregated_at >= NOW() - INTERVAL '"'"'48 hours'"'"'" 2>&1
rm -f /tmp/_rollup_env'

n="$(bash "$REPO_ROOT/scripts/launch/ssm_exec_staging.sh" "$remote" 2>&1 | tr -d '[:space:]')"

if ! [[ "$n" =~ ^[0-9]+$ ]]; then
  echo "usage_daily_rows_48h=$n (non-numeric)"
  exit 1
fi
if [ "$n" -le 0 ]; then
  echo "usage_daily_rows_48h=0 (stale per check_rollup_current contract)"
  exit 1
fi
echo "usage_daily_rows_48h=$n (>0)"
exit 0
