set -euo pipefail
echo "=== pre_restart_diag ==="
date -u +%Y-%m-%dT%H:%M:%SZ
systemctl is-active fjcloud-api || true
systemctl status fjcloud-api --no-pager -l || true
journalctl -u fjcloud-api --since "30 minutes ago" --no-pager || true
ss -ltnp | grep -E ":3001\\b" || true
awk -F= '/^(PORT|HOST|BIND)=/ { print } /^(DATABASE_URL|STRIPE_SECRET_KEY|STRIPE_PUBLISHABLE_KEY|STRIPE_WEBHOOK_SECRET)=/ { print $1 "=<redacted>" }' /etc/fjcloud/env || true

echo "=== restart_and_verify ==="
sudo systemctl restart fjcloud-api
systemctl is-active fjcloud-api
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3001/health; then
    echo
    echo "health_ok_after_seconds=$i"
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "health_check_timeout_after_30s" >&2
    exit 7
  fi
done
journalctl -u fjcloud-api --since "10 minutes ago" --no-pager
