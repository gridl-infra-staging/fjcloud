#!/usr/bin/env bash
# outside_aws_health_check.sh — one-shot external health probe owner.
#
# This script is the single owner for:
# - target URLs
# - curl transport flags
# - exit-code behavior
# - target-specific failure logging
#
# The GitHub Actions workflow is wiring only and must not duplicate probe logic.
# Keep the one-shot behavior here: fail immediately when any external target is
# unavailable so staging gets a clear outside-AWS outage signal.

set -euo pipefail

CURL_MAX_TIME_SECONDS=10
EXIT_PROBE_FAILURE=2

TARGET_URLS=(
    "https://cloud.flapjack.foo/health"
    "https://api.flapjack.foo/health"
)

log() {
    echo "[outside-aws-health] $*"
}

probe_target() {
    local target_url="$1"
    local http_code

    # Owner contract: one-shot probe with -fsSL and --max-time 10.
    if ! http_code="$(curl -fsSL --max-time "$CURL_MAX_TIME_SECONDS" -o /dev/null -w '%{http_code}' "$target_url")"; then
        log "FAIL target=${target_url} reason=transport_error"
        return 1
    fi

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log "FAIL target=${target_url} reason=http_status status=${http_code}"
        return 1
    fi

    log "OK target=${target_url} status=${http_code}"
    return 0
}

main() {
    local target_url
    for target_url in "${TARGET_URLS[@]}"; do
        if ! probe_target "$target_url"; then
            return "$EXIT_PROBE_FAILURE"
        fi
    done

    log "all outside-AWS health targets succeeded"
    return 0
}

main "$@"
