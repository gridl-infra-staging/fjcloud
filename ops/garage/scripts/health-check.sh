#!/usr/bin/env bash
# health-check.sh — Probe Garage admin and S3 API endpoints
#
# Returns exit 0 if both endpoints are healthy, exit 1 otherwise.
# Suitable for cron, monitoring hooks, or manual verification.
#
# Usage: health-check.sh [-q]
#   -q  Quiet mode: only output on failure
#
# Health criteria:
#   Admin API (127.0.0.1:3903): HTTP 200 on /health
#   S3 API    (127.0.0.1:3900): HTTP 200 or 403 (OQ-10: 403 = S3 up, auth required)

set -euo pipefail

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

QUIET=false
if [[ "${1:-}" == "-q" ]]; then
  QUIET=true
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ADMIN_ENDPOINT="http://127.0.0.1:3903"
S3_ENDPOINT="http://127.0.0.1:3900"
TIMEOUT=5

TAG="garage-health"
FAILURES=0

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

log() {
  if [[ "$QUIET" == false ]]; then
    echo "$1"
  fi
}

# ---------------------------------------------------------------------------
# 1. Check systemd service status
# ---------------------------------------------------------------------------

if systemctl is-active --quiet garage 2>/dev/null; then
  log "systemd:  garage.service active"
else
  log "systemd:  garage.service NOT active"
  logger -t "$TAG" "FAIL: garage.service not active"
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# 2. Check admin API (/health endpoint)
# ---------------------------------------------------------------------------

ADMIN_HTTP="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$TIMEOUT" "${ADMIN_ENDPOINT}/health" 2>/dev/null || echo "000")"

if [[ "$ADMIN_HTTP" == "200" ]]; then
  log "admin:    ${ADMIN_ENDPOINT}/health → ${ADMIN_HTTP} OK"
else
  log "admin:    ${ADMIN_ENDPOINT}/health → ${ADMIN_HTTP} FAIL"
  logger -t "$TAG" "FAIL: admin API returned ${ADMIN_HTTP}"
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# 3. Check S3 API (unauthenticated probe — expect 200 or 403)
# ---------------------------------------------------------------------------

S3_HTTP="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$TIMEOUT" "${S3_ENDPOINT}/" 2>/dev/null || echo "000")"

if [[ "$S3_HTTP" == "200" || "$S3_HTTP" == "403" ]]; then
  log "s3:       ${S3_ENDPOINT}/ → ${S3_HTTP} OK"
else
  log "s3:       ${S3_ENDPOINT}/ → ${S3_HTTP} FAIL"
  logger -t "$TAG" "FAIL: S3 API returned ${S3_HTTP}"
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# 4. Result
# ---------------------------------------------------------------------------

if [[ "$FAILURES" -gt 0 ]]; then
  log ""
  log "UNHEALTHY: ${FAILURES} check(s) failed"
  logger -t "$TAG" "UNHEALTHY: ${FAILURES} check(s) failed"
  exit 1
fi

log ""
log "HEALTHY: all checks passed"
exit 0
