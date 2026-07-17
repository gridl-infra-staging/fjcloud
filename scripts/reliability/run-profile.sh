#!/usr/bin/env bash
# run-profile.sh — Run a capacity profiling session for a single document tier.
# Usage: run-profile.sh <tier>
#   tier: 1k | 10k | 100k
#
# Prerequisites: integration stack running (scripts/integration-up.sh)
# Set RELIABILITY=1 to enable; otherwise exits gracefully.

set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/metrics.sh
source "$PROFILE_DIR/lib/metrics.sh"

# ---------------------------------------------------------------------------
# RELIABILITY gate: skip gracefully if not enabled
# ---------------------------------------------------------------------------
if [ "${RELIABILITY:-0}" != "1" ]; then
    rlog "RELIABILITY=1 not set — skipping profiling. Set RELIABILITY=1 to run."
    exit 0
fi

require_jq_or_python

TIER="${1:?Usage: run-profile.sh <1k|10k|100k>}"
FLAPJACK_BASE="${FLAPJACK_BASE:-http://localhost:${FLAPJACK_PORT:-7799}}"

case "$TIER" in
    1k|10k|100k) ;;
    *) rdie "Invalid tier: $TIER (expected 1k, 10k, or 100k)" ;;
esac

rlog "=== Profiling tier: $TIER ==="
require_stack

# ---------------------------------------------------------------------------
# Phase 1: Capture idle baseline
# ---------------------------------------------------------------------------
rlog "Phase 1: Capturing idle baseline..."
idle_cpu="$(capture_cpu_snapshot)"
idle_mem="$(capture_mem_snapshot "$FLAPJACK_BASE")"
idle_disk="$(capture_disk_snapshot "$FLAPJACK_BASE")"

# ---------------------------------------------------------------------------
# Phase 2: Seed documents
# ---------------------------------------------------------------------------
rlog "Phase 2: Seeding documents..."
INDEX_NAME="$("$PROFILE_DIR/seed-documents.sh" "$TIER")"

# Brief pause for indexing to settle
sleep 2

# ---------------------------------------------------------------------------
# Phase 3: Capture post-seed metrics
# ---------------------------------------------------------------------------
rlog "Phase 3: Capturing post-seed metrics..."
seed_cpu="$(capture_cpu_snapshot)"
seed_mem="$(capture_mem_snapshot "$FLAPJACK_BASE")"
seed_disk="$(capture_disk_snapshot "$FLAPJACK_BASE")"

# ---------------------------------------------------------------------------
# Phase 4: Steady query load + latency capture
# ---------------------------------------------------------------------------
rlog "Phase 4: Running steady query load..."
QUERY_ITERATIONS="${RELIABILITY_QUERY_ITERATIONS:-200}"
latency_sum=0
latency_min=999999
latency_max=0
latency_count=0
declare -a latencies=()

for i in $(seq 1 "$QUERY_ITERATIONS"); do
    start_ms="$(python3 -c "import time; print(int(time.time()*1000))")"
    curl_flapjack POST "${FLAPJACK_BASE}/1/indexes/${INDEX_NAME}/query" \
        -H "Content-Type: application/json" \
        -d "{\"query\": \"document\", \"hitsPerPage\": 20}" >/dev/null 2>&1 || true
    end_ms="$(python3 -c "import time; print(int(time.time()*1000))")"
    elapsed=$((end_ms - start_ms))
    latencies+=("$elapsed")
    latency_sum=$((latency_sum + elapsed))
    [ "$elapsed" -lt "$latency_min" ] && latency_min="$elapsed"
    [ "$elapsed" -gt "$latency_max" ] && latency_max="$elapsed"
    latency_count=$((latency_count + 1))
done

# Capture under-load metrics
query_cpu="$(capture_cpu_snapshot)"
query_mem="$(capture_mem_snapshot "$FLAPJACK_BASE")"

# Calculate percentiles
latency_stats="$(
    python3 - "${latencies[@]}" <<'PY'
import json
import sys

latencies = sorted(int(value) for value in sys.argv[1:])
n = len(latencies)

if n == 0:
    print(json.dumps({
        'p50_ms': 0,
        'p95_ms': 0,
        'p99_ms': 0,
        'min_ms': 0,
        'max_ms': 0,
        'mean_ms': 0,
        'count': 0,
    }))
else:
    p50 = latencies[int(n * 0.50)]
    p95 = latencies[int(n * 0.95)]
    p99 = latencies[min(int(n * 0.99), n - 1)]
    mean = sum(latencies) / n
    print(json.dumps({
        'p50_ms': p50,
        'p95_ms': p95,
        'p99_ms': p99,
        'min_ms': latencies[0],
        'max_ms': latencies[-1],
        'mean_ms': round(mean, 2),
        'count': n,
    }))
PY
)"

# ---------------------------------------------------------------------------
# Phase 5: Write profile artifacts
# ---------------------------------------------------------------------------
rlog "Phase 5: Writing profile artifacts..."

# CPU envelope
cpu_envelope="{\"idle\": ${idle_cpu}, \"seeding\": ${seed_cpu}, \"query_load\": ${query_cpu}}"
write_profile "$TIER" "cpu" "$cpu_envelope"

# Memory envelope
mem_envelope="{\"idle\": ${idle_mem}, \"post_seed\": ${seed_mem}, \"query_load\": ${query_mem}}"
write_profile "$TIER" "mem" "$mem_envelope"

# Disk envelope
disk_envelope="{\"post_seed\": ${seed_disk}}"
write_profile "$TIER" "disk" "$disk_envelope"

# Latency envelope
write_profile "$TIER" "latency" "$latency_stats"

rlog "=== Profiling complete for tier: $TIER ==="
