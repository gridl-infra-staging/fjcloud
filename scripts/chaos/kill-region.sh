#!/usr/bin/env bash
# kill-region.sh — Kill a Flapjack region to test HA failover detection.
#
# The health monitor (60s cycle, 3 failures = unhealthy) should detect the
# killed region and log a "deployment unhealthy" alert. Restart with
# restart-region.sh to verify recovery detection.
#
# Usage:
#   scripts/chaos/kill-region.sh eu-west-1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PID_DIR="$REPO_ROOT/.local"

REGION="${1:?Usage: kill-region.sh <region>}"
PID_FILE="$PID_DIR/flapjack-${REGION}.pid"

if [ ! -f "$PID_FILE" ]; then
    echo "ERROR: No PID file for flapjack-${REGION} at ${PID_FILE}" >&2
    exit 1
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    echo "Killed flapjack-${REGION} (PID ${PID})"
    _interval="${REGION_FAILOVER_CYCLE_INTERVAL_SECS:-60}"
    _threshold="${REGION_FAILOVER_UNHEALTHY_THRESHOLD:-3}"
    _detect_secs=$(( _interval * _threshold ))
    echo "Health monitor should detect unhealthy after ~${_threshold} cycles (${_detect_secs}s with ${_interval}s interval)"
else
    echo "flapjack-${REGION} not running (PID ${PID} is dead)"
fi
rm -f "$PID_FILE"
