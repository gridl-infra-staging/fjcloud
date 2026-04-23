#!/usr/bin/env bash
# Shared health-check helpers for shell scripts.
#
# Callers must define:
#   log "<message>"

wait_for_health() {
    local url="$1" name="$2" max_wait="${3:-15}"
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        if curl -sf "$url" >/dev/null 2>&1; then
            log "$name is healthy ($url)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log "$name failed health check after ${max_wait}s ($url)"
    return 1
}

check_port_available() {
    local port="$1"
    local name="$2"

    if ! command -v lsof >/dev/null 2>&1; then
        return 0
    fi

    if lsof -i :"$port" -sTCP:LISTEN -P >/dev/null 2>&1; then
        log "port $port is already in use (needed for $name)"
        return 1
    fi
}
