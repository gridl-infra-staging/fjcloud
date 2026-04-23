#!/usr/bin/env bash
# run-aggregation-job.sh — Run the aggregation job for a target date.
#
# Rolls up raw usage_records into daily aggregates in usage_daily.
# Idempotent — safe to run multiple times for the same date.
# Defaults to yesterday (UTC) when no date argument is provided.
#
# Usage:
#   scripts/run-aggregation-job.sh                # yesterday
#   scripts/run-aggregation-job.sh 2026-03-27     # specific date

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

log() { echo "[aggregation-job] $*"; }
die() { echo "[aggregation-job] ERROR: $*" >&2; exit 1; }

load_env_file "$REPO_ROOT/.env.local"

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is required in .env.local"

# Compute yesterday's date. macOS date uses -v, GNU date uses -d.
if [ -n "${1:-}" ]; then
    TARGET_DATE="$1"
else
    TARGET_DATE="$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)"
fi

log "Running aggregation for ${TARGET_DATE}..."

cd "$REPO_ROOT"
DATABASE_URL="$DATABASE_URL" \
TARGET_DATE="$TARGET_DATE" \
    cargo run --manifest-path infra/Cargo.toml -p aggregation-job

log "Aggregation complete for ${TARGET_DATE}."
