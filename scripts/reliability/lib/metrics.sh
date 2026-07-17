#!/usr/bin/env bash
# Shared metric capture functions for reliability profiling.
# Sourced by run-profile.sh and capture scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELIABILITY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$RELIABILITY_DIR/../.." && pwd)"
PROFILES_DIR="$RELIABILITY_DIR/profiles"

API_PORT="${API_PORT:-3099}"
API_BASE="http://localhost:${API_PORT}"
ADMIN_KEY="${ADMIN_KEY:-integration-test-admin-key}"
FLAPJACK_ADMIN_KEY_DEFAULT="${FLAPJACK_ADMIN_KEY_DEFAULT:-fj_local_dev_admin_key_000000000000}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
rlog() { echo "[reliability] $*" >&2; }
rdie() { echo "[reliability] ERROR: $*" >&2; exit 1; }

iso_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

read_repo_env_value() {
    local env_file="$1"
    local target_key="$2"

    [ -f "$env_file" ] || return 1

    local line key value quote_char
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"

        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            continue
        fi

        key="${BASH_REMATCH[2]}"
        [ "$key" = "$target_key" ] || continue

        value="${BASH_REMATCH[3]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [ -n "$value" ]; then
            quote_char="${value:0:1}"
            if { [ "$quote_char" = "'" ] || [ "$quote_char" = '"' ]; } && [ "${value: -1}" = "$quote_char" ]; then
                value="${value:1:${#value}-2}"
            fi
        fi

        printf '%s\n' "$value"
        return 0
    done < "$env_file"

    return 1
}

resolve_flapjack_admin_key() {
    if [ -n "${FLAPJACK_ADMIN_KEY:-}" ]; then
        printf '%s\n' "$FLAPJACK_ADMIN_KEY"
        return 0
    fi

    if read_repo_env_value "$REPO_ROOT/.env.local" FLAPJACK_ADMIN_KEY >/dev/null 2>&1; then
        read_repo_env_value "$REPO_ROOT/.env.local" FLAPJACK_ADMIN_KEY
        return 0
    fi

    printf '%s\n' "$FLAPJACK_ADMIN_KEY_DEFAULT"
}

require_stack() {
    if ! curl -sf "${API_BASE}/health" >/dev/null 2>&1; then
        rdie "Integration stack not running at ${API_BASE}. Run scripts/integration-up.sh first."
    fi
}

require_jq_or_python() {
    if command -v jq >/dev/null 2>&1; then
        JSON_TOOL="jq"
    elif command -v python3 >/dev/null 2>&1; then
        JSON_TOOL="python3"
    else
        rdie "Need jq or python3 for JSON processing"
    fi
}

curl_flapjack() {
    local method="$1"
    local url="$2"
    shift 2
    local flapjack_admin_key
    flapjack_admin_key="$(resolve_flapjack_admin_key)"

    curl -sf -X "$method" "$url" \
        -H "X-Algolia-API-Key: ${flapjack_admin_key}" \
        -H "X-Algolia-Application-Id: flapjack" \
        "$@"
}

# ---------------------------------------------------------------------------
# CPU capture: uses vm_stat (macOS) or /proc/stat (Linux)
# Returns JSON with idle/active percentages.
# ---------------------------------------------------------------------------
capture_cpu_snapshot() {
    if [ "$(uname)" = "Darwin" ]; then
        # macOS: vm_stat gives page-based stats
        local output
        output="$(vm_stat 2>/dev/null)" || { echo '{"cpu_user_pct": 0, "cpu_idle_pct": 100}'; return; }
        # Use top for CPU on macOS (single sample)
        local cpu_line
        cpu_line="$(top -l 1 -n 0 2>/dev/null | grep -E 'CPU usage' || echo '')"
        if [ -n "$cpu_line" ]; then
            local user idle
            user="$(echo "$cpu_line" | sed -E 's/.*([0-9]+\.[0-9]+)% user.*/\1/' || echo '0')"
            idle="$(echo "$cpu_line" | sed -E 's/.*([0-9]+\.[0-9]+)% idle.*/\1/' || echo '100')"
            echo "{\"cpu_user_pct\": $user, \"cpu_idle_pct\": $idle}"
        else
            echo '{"cpu_user_pct": 0, "cpu_idle_pct": 100}'
        fi
    else
        # Linux: /proc/stat
        local line
        line="$(head -1 /proc/stat)"
        local user nice system idle
        read -r _ user nice system idle _ <<< "$line"
        local total=$((user + nice + system + idle))
        if [ "$total" -gt 0 ]; then
            python3 -c "
user_pct = round(($user + $nice) / $total * 100, 2)
idle_pct = round($idle / $total * 100, 2)
print('{\"cpu_user_pct\": ' + str(user_pct) + ', \"cpu_idle_pct\": ' + str(idle_pct) + '}')
"
        else
            echo '{"cpu_user_pct": 0, "cpu_idle_pct": 100}'
        fi
    fi
}

# ---------------------------------------------------------------------------
# Memory capture: RSS from /metrics endpoint or system memory
# ---------------------------------------------------------------------------
capture_mem_snapshot() {
    local flapjack_url="${1:-http://localhost:7799}"
    local metrics
    metrics="$(curl_flapjack GET "${flapjack_url}/metrics" 2>/dev/null)" || { echo '{"rss_bytes": 0}'; return; }
    local heap_bytes
    heap_bytes="$(echo "$metrics" | grep -E '^flapjack_memory_heap_bytes ' | awk '{print $2}' | head -1)" || heap_bytes="0"
    [ -z "$heap_bytes" ] && heap_bytes="0"
    echo "{\"rss_bytes\": ${heap_bytes}}"
}

# ---------------------------------------------------------------------------
# Disk capture: from /internal/storage endpoint
# ---------------------------------------------------------------------------
capture_disk_snapshot() {
    local flapjack_url="${1:-http://localhost:7799}"
    local storage
    storage="$(curl_flapjack GET "${flapjack_url}/internal/storage" 2>/dev/null)" || { echo '{"disk_bytes": 0}'; return; }
    local total_bytes
    total_bytes="$(echo "$storage" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
total = sum(t.get('bytes', 0) for t in d.get('tenants', []))
print(total)
" 2>/dev/null)" || total_bytes="0"
    echo "{\"disk_bytes\": ${total_bytes}}"
}

# ---------------------------------------------------------------------------
# Write a profile artifact JSON file
# ---------------------------------------------------------------------------
write_profile() {
    local tier="$1" metric="$2" envelope_json="$3"
    mkdir -p "$PROFILES_DIR"
    local outfile="$PROFILES_DIR/${tier}_${metric}.json"
    echo "$envelope_json" | python3 -c "
import json, sys
envelope = json.loads(sys.stdin.read())
profile = {
    'tier': sys.argv[1],
    'timestamp': sys.argv[2],
    'metric': sys.argv[3],
    'envelope': envelope
}
with open(sys.argv[4], 'w') as f:
    json.dump(profile, f, indent=2)
    f.write('\n')
" "$tier" "$(iso_timestamp)" "$metric" "$outfile"
    rlog "Wrote profile: $outfile"
}
