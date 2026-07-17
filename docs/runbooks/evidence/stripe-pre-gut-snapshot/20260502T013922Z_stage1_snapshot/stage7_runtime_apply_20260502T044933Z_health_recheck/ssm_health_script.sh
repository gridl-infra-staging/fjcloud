set -euo pipefail
sudo systemctl restart fjcloud-api
restart_rc=$?
systemctl is-active fjcloud-api
active_rc=$?
curl -fsS http://127.0.0.1:3001/health
curl_rc=$?
journalctl -u fjcloud-api --since "10 minutes ago" --no-pager
journal_rc=$?
printf "restart_rc=%s active_rc=%s curl_rc=%s journal_rc=%s\n" "$restart_rc" "$active_rc" "$curl_rc" "$journal_rc"
