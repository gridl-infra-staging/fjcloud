#!/usr/bin/env bash
# Generates minimal valid profile JSON files for CI/dev use.
#
# Produces all 12 per-metric artifacts ({tier}_{metric}.json for 3 tiers x 4 metrics)
# AND summary.json under scripts/reliability/profiles/.
#
# Uses the current PROFILE_*K constant values from infra/api/tests/common/capacity_profiles.rs
# as the "measured" values so Rust drift tests pass without a live flapjack stack.
#
# For real profiling data, run:
#   RELIABILITY=1 scripts/reliability/capture-all.sh
#
# Usage:
#   scripts/reliability/seed-test-profiles.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"

mkdir -p "$PROFILES_DIR"

# Single source of truth: capacity_profiles.rs
CAPACITY_PROFILES="$SCRIPT_DIR/../../infra/api/tests/common/capacity_profiles.rs"
CAPACITY_PARSER="$SCRIPT_DIR/lib/parse_capacity_profiles.py"
if [ ! -f "$CAPACITY_PROFILES" ]; then
    echo "[seed-profiles] ERROR: cannot find $CAPACITY_PROFILES" >&2
    exit 1
fi
if [ ! -f "$CAPACITY_PARSER" ]; then
    echo "[seed-profiles] ERROR: cannot find $CAPACITY_PARSER" >&2
    exit 1
fi

# Delegate all JSON generation to Python (avoids bash 3.2 associative array limitation).
# Python reads mem_rss_bytes and disk_bytes via shared parser helper so
# capacity_profiles.rs remains the single source of truth.
python3 - "$PROFILES_DIR" "$CAPACITY_PROFILES" "$CAPACITY_PARSER" <<'PYEOF'
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

profiles_dir = sys.argv[1]
capacity_profiles_path = sys.argv[2]
capacity_parser_path = sys.argv[3]

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------------------------
# Parse constants from capacity_profiles.rs (single source of truth)
# ---------------------------------------------------------------------------

try:
    parsed_profiles = json.loads(
        subprocess.check_output(
            [sys.executable, capacity_parser_path, capacity_profiles_path],
            text=True,
        )
    )
except subprocess.CalledProcessError:
    print("[seed-profiles] ERROR: failed parsing capacity profile constants", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError:
    print("[seed-profiles] ERROR: parser returned invalid JSON", file=sys.stderr)
    sys.exit(1)

mem_1k = parsed_profiles["1k"]["mem_rss_bytes"]
disk_1k = parsed_profiles["1k"]["disk_bytes"]
mem_10k = parsed_profiles["10k"]["mem_rss_bytes"]
disk_10k = parsed_profiles["10k"]["disk_bytes"]
mem_100k = parsed_profiles["100k"]["mem_rss_bytes"]
disk_100k = parsed_profiles["100k"]["disk_bytes"]

print(f"[seed-profiles] parsed from Rust: 1k=({mem_1k},{disk_1k}) 10k=({mem_10k},{disk_10k}) 100k=({mem_100k},{disk_100k})", file=sys.stderr)

# Per-tier config: mem/disk parsed from Rust, cpu/latency are reasonable placeholders.
TIERS = {
    "1k": {
        "mem_rss_bytes": mem_1k,
        "disk_bytes":    disk_1k,
        # CPU placeholder: idle / seeding / query_load phases
        "cpu": {
            "idle":       {"cpu_user_pct": 2,  "cpu_idle_pct": 98},
            "seeding":    {"cpu_user_pct": 10, "cpu_idle_pct": 90},
            "query_load": {"cpu_user_pct": 20, "cpu_idle_pct": 80},
        },
        # Latency placeholder
        "latency": {
            "p50_ms": 5, "p95_ms": 15, "p99_ms": 30,
            "min_ms": 1, "max_ms": 50, "mean_ms": 8, "count": 1000,
        },
    },
    "10k": {
        "mem_rss_bytes": mem_10k,
        "disk_bytes":    disk_10k,
        "cpu": {
            "idle":       {"cpu_user_pct": 3,  "cpu_idle_pct": 97},
            "seeding":    {"cpu_user_pct": 15, "cpu_idle_pct": 85},
            "query_load": {"cpu_user_pct": 30, "cpu_idle_pct": 70},
        },
        "latency": {
            "p50_ms": 10, "p95_ms": 25, "p99_ms": 50,
            "min_ms": 2,  "max_ms": 100, "mean_ms": 14, "count": 1000,
        },
    },
    "100k": {
        "mem_rss_bytes": mem_100k,
        "disk_bytes":    disk_100k,
        "cpu": {
            "idle":       {"cpu_user_pct": 5,  "cpu_idle_pct": 95},
            "seeding":    {"cpu_user_pct": 20, "cpu_idle_pct": 80},
            "query_load": {"cpu_user_pct": 40, "cpu_idle_pct": 60},
        },
        "latency": {
            "p50_ms": 15, "p95_ms": 40, "p99_ms": 80,
            "min_ms": 3,  "max_ms": 200, "mean_ms": 22, "count": 1000,
        },
    },
}


def write(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


summary_tiers = {}

for tier, cfg in TIERS.items():
    mem_bytes  = cfg["mem_rss_bytes"]
    disk_bytes = cfg["disk_bytes"]

    # cpu
    cpu_envelope = cfg["cpu"]
    cpu_profile = {
        "tier": tier,
        "timestamp": now,
        "metric": "cpu",
        "envelope": cpu_envelope,
    }
    write(os.path.join(profiles_dir, f"{tier}_cpu.json"), cpu_profile)
    print(f"[seed-profiles] wrote {tier}_cpu.json", file=sys.stderr)

    # mem — use constant as rss_bytes for all three phases
    mem_envelope = {
        "idle":       {"rss_bytes": mem_bytes},
        "post_seed":  {"rss_bytes": mem_bytes},
        "query_load": {"rss_bytes": mem_bytes},
    }
    mem_profile = {
        "tier": tier,
        "timestamp": now,
        "metric": "mem",
        "envelope": mem_envelope,
    }
    write(os.path.join(profiles_dir, f"{tier}_mem.json"), mem_profile)
    print(f"[seed-profiles] wrote {tier}_mem.json", file=sys.stderr)

    # disk
    disk_envelope = {
        "post_seed": {"disk_bytes": disk_bytes},
    }
    disk_profile = {
        "tier": tier,
        "timestamp": now,
        "metric": "disk",
        "envelope": disk_envelope,
    }
    write(os.path.join(profiles_dir, f"{tier}_disk.json"), disk_profile)
    print(f"[seed-profiles] wrote {tier}_disk.json", file=sys.stderr)

    # latency
    lat_envelope = cfg["latency"]
    lat_profile = {
        "tier": tier,
        "timestamp": now,
        "metric": "latency",
        "envelope": lat_envelope,
    }
    write(os.path.join(profiles_dir, f"{tier}_latency.json"), lat_profile)
    print(f"[seed-profiles] wrote {tier}_latency.json", file=sys.stderr)

    summary_tiers[tier] = {
        "cpu":     cpu_envelope,
        "mem":     mem_envelope,
        "disk":    disk_envelope,
        "latency": lat_envelope,
    }

# summary.json
summary = {
    "generated_at": now,
    "tiers": summary_tiers,
}
write(os.path.join(profiles_dir, "summary.json"), summary)
print("[seed-profiles] wrote summary.json", file=sys.stderr)

count = len(os.listdir(profiles_dir))
print(f"[seed-profiles] done — seeded {count} artifacts in {profiles_dir}", file=sys.stderr)
PYEOF
