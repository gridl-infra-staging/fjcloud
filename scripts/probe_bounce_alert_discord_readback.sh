#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXIT_USAGE=2
EXIT_PRECONDITION=3
EXIT_RUNTIME=1

usage() {
    echo "Usage: bash scripts/probe_bounce_alert_discord_readback.sh"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 0 ]]; then
    echo "ERROR: this probe takes no positional arguments" >&2
    usage >&2
    exit "$EXIT_USAGE"
fi

alert_delivery_script="${PROBE_ALERT_DELIVERY_SCRIPT:-$SCRIPT_DIR/probe_alert_delivery.sh}"
[[ -f "$alert_delivery_script" && -r "$alert_delivery_script" ]] || {
    echo "ERROR: missing readable alert-delivery owner script $alert_delivery_script" >&2
    exit "$EXIT_PRECONDITION"
}

owner_output="$(bash "$alert_delivery_script" --readback 2>&1)" || {
    echo "ERROR: delegated readback owner probe failed: $owner_output" >&2
    exit "$EXIT_RUNTIME"
}

owner_nonce="$(printf '%s\n' "$owner_output" | sed -n "s/.*nonce=\\([^[:space:]]*\\).*/\\1/p" | head -n 1)"
if [[ -z "$owner_nonce" ]]; then
    echo "ERROR: delegated readback owner output missing nonce: $owner_output" >&2
    exit "$EXIT_RUNTIME"
fi

echo "$owner_output"
echo "TERMINUS: discord message contains nonce nonce=$owner_nonce"
