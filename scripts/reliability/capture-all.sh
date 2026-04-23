#!/usr/bin/env bash
# capture-all.sh — Run profiling for all three tiers and produce summary.json.
# Usage: RELIABILITY=1 ./capture-all.sh
#
# Prerequisites: integration stack running (scripts/integration-up.sh)

set -euo pipefail

CAPTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/metrics.sh
source "$CAPTURE_DIR/lib/metrics.sh"

if [ "${RELIABILITY:-0}" != "1" ]; then
    rlog "RELIABILITY=1 not set — skipping. Set RELIABILITY=1 to run."
    exit 0
fi

require_stack
require_jq_or_python

TIERS=("1k" "10k" "100k")

rlog "=== Capturing all capacity baselines ==="

for tier in "${TIERS[@]}"; do
    rlog "--- Starting tier: $tier ---"
    "$CAPTURE_DIR/run-profile.sh" "$tier"
    rlog "--- Completed tier: $tier ---"
    echo ""
done

# ---------------------------------------------------------------------------
# Generate summary.json from individual profile artifacts
# ---------------------------------------------------------------------------
rlog "Generating summary.json..."

python3 -c "
import json, os, glob

profiles_dir = '$PROFILES_DIR'
tiers = ['1k', '10k', '100k']
metrics = ['cpu', 'mem', 'disk', 'latency']

summary = {
    'generated_at': '$(iso_timestamp)',
    'tiers': {}
}

for tier in tiers:
    summary['tiers'][tier] = {}
    for metric in metrics:
        path = os.path.join(profiles_dir, f'{tier}_{metric}.json')
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
            summary['tiers'][tier][metric] = data.get('envelope', {})
        else:
            summary['tiers'][tier][metric] = None

outpath = os.path.join(profiles_dir, 'summary.json')
with open(outpath, 'w') as f:
    json.dump(summary, f, indent=2)
    f.write('\n')
print(f'Wrote {outpath}')
"

rlog "=== All baselines captured ==="
