#!/usr/bin/env bash
# run_monitor.sh — detached 4-hour monitor wrapper.
# Runs queries.sh on a 30-minute cadence (8 ticks total). Never blocks the
# session. Records the start/end timestamps in dispatch.md (already pre-seeded).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
RUNNER_LOG="$BUNDLE_DIR/runner.log"

TICK_INTERVAL_SEC="${TICK_INTERVAL_SEC:-1800}"   # 30 min
TICK_COUNT="${TICK_COUNT:-8}"                    # 8 ticks * 30 min = 4 h

echo "[run_monitor] start $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$ ticks=$TICK_COUNT interval=${TICK_INTERVAL_SEC}s" >>"$RUNNER_LOG"

for i in $(seq 1 "$TICK_COUNT"); do
  echo "[run_monitor] tick $i/$TICK_COUNT at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$RUNNER_LOG"
  bash "$BUNDLE_DIR/queries.sh" >>"$RUNNER_LOG" 2>&1 || \
    echo "[run_monitor] tick $i: queries.sh exited non-zero (continuing)" >>"$RUNNER_LOG"
  if [ "$i" -lt "$TICK_COUNT" ]; then
    sleep "$TICK_INTERVAL_SEC"
  fi
done

echo "[run_monitor] end $(date -u +%Y-%m-%dT%H:%M:%SZ) pid=$$" >>"$RUNNER_LOG"
