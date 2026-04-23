#!/usr/bin/env bash
# Seed deterministic capacity profile artifacts for CI and local development.
#
# Writes 12 per-metric JSON files (3 tiers × 4 metrics) and a summary.json
# to scripts/reliability/profiles/. Does NOT require a live integration stack.
#
# Values are realistic placeholders matching the PROFILE_* constants in
# infra/api/tests/common/capacity_profiles.rs. Real profiling runs via
# capture-all.sh will overwrite these with measured data.
#
# Usage:
#   bash scripts/reliability/seed-profiles.sh
#
# Environment:
#   RELIABILITY_SEED_TIMESTAMP  Override the timestamp for reproducible output.
#                               Default: current UTC time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/metrics.sh"

TIMESTAMP="${RELIABILITY_SEED_TIMESTAMP:-$(iso_timestamp)}"

# Override iso_timestamp so write_profile picks up our fixed timestamp.
iso_timestamp() { echo "$TIMESTAMP"; }

# ---------------------------------------------------------------------------
# 1K tier — ~1,000 documents
# ---------------------------------------------------------------------------
write_profile "1k" "cpu" '{"idle": 0.5, "seeding": 3.2, "query_load": 5.1}'
write_profile "1k" "mem" '{"idle": 25000000, "post_seed": 50000000, "query_load": 55000000}'
write_profile "1k" "disk" '{"post_seed": 100000000}'
write_profile "1k" "latency" '{"p50_ms": 2, "p95_ms": 8, "p99_ms": 15, "min_ms": 1, "max_ms": 25, "mean_ms": 3.4, "count": 200}'

# ---------------------------------------------------------------------------
# 10K tier — ~10,000 documents
# ---------------------------------------------------------------------------
write_profile "10k" "cpu" '{"idle": 0.5, "seeding": 12.8, "query_load": 18.5}'
write_profile "10k" "mem" '{"idle": 25000000, "post_seed": 400000000, "query_load": 420000000}'
write_profile "10k" "disk" '{"post_seed": 1000000000}'
write_profile "10k" "latency" '{"p50_ms": 8, "p95_ms": 35, "p99_ms": 72, "min_ms": 4, "max_ms": 150, "mean_ms": 14.2, "count": 200}'

# ---------------------------------------------------------------------------
# 100K tier — ~100,000 documents
# ---------------------------------------------------------------------------
write_profile "100k" "cpu" '{"idle": 0.5, "seeding": 45.0, "query_load": 62.3}'
write_profile "100k" "mem" '{"idle": 25000000, "post_seed": 2000000000, "query_load": 2100000000}'
write_profile "100k" "disk" '{"post_seed": 10000000000}'
write_profile "100k" "latency" '{"p50_ms": 25, "p95_ms": 95, "p99_ms": 210, "min_ms": 12, "max_ms": 450, "mean_ms": 38.7, "count": 200}'

# ---------------------------------------------------------------------------
# summary.json — aggregate envelope for all tiers
# ---------------------------------------------------------------------------
rlog "Generating summary.json..."
python3 -c "
import json, os

profiles_dir = '$PROFILES_DIR'
tiers = ['1k', '10k', '100k']
metrics = ['cpu', 'mem', 'disk', 'latency']

summary = {
    'generated_at': '$TIMESTAMP',
    'tiers': {}
}

for tier in tiers:
    summary['tiers'][tier] = {}
    for metric in metrics:
        path = os.path.join(profiles_dir, f'{tier}_{metric}.json')
        with open(path) as f:
            data = json.load(f)
        summary['tiers'][tier][metric] = data['envelope']

out_path = os.path.join(profiles_dir, 'summary.json')
with open(out_path, 'w') as f:
    json.dump(summary, f, indent=2)
    f.write('\n')
"
rlog "Wrote summary: $PROFILES_DIR/summary.json"
rlog "Done — 12 profile artifacts + summary.json seeded."
