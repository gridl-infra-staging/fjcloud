#!/usr/bin/env bash
# local_play.sh - One-command fresh local demo launcher.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  scripts/local_play.sh             Clean-reset this repo's local stack, then start the local demo
  scripts/local_play.sh --keep-data Stop this repo's tracked local stack, keep data, then start
  scripts/local_play.sh --clean     Same as the default
  scripts/local_play.sh --help
EOF
}

port_available() {
    local port="$1"
    ! command -v lsof >/dev/null 2>&1 || ! lsof -i :"$port" -sTCP:LISTEN -P >/dev/null 2>&1
}

choose_available_port() {
    local start_port="$1"
    local step="$2"
    local attempts="$3"
    local port="$start_port"
    local i=0

    while [ "$i" -lt "$attempts" ]; do
        if port_available "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        port=$((port + step))
        i=$((i + 1))
    done

    echo "ERROR: no free port found starting at ${start_port}" >&2
    return 1
}

prepare_demo_ports() {
    if [ -z "${LOCAL_DB_PORT:-}" ]; then
        LOCAL_DB_PORT="$(choose_available_port 5432 100 20)"
        export LOCAL_DB_PORT
    fi
    if [ -z "${DATABASE_URL:-}" ]; then
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:${LOCAL_DB_PORT}/fjcloud_dev"
        export DATABASE_URL
    fi
    if [ -z "${LOCAL_SMTP_PORT:-}" ]; then
        LOCAL_SMTP_PORT="$(choose_available_port 1025 100 20)"
        export LOCAL_SMTP_PORT
    fi
    if [ -z "${LOCAL_MAILPIT_UI_PORT:-}" ]; then
        LOCAL_MAILPIT_UI_PORT="$(choose_available_port 8025 100 20)"
        export LOCAL_MAILPIT_UI_PORT
    fi

    MAILPIT_API_URL="http://localhost:${LOCAL_MAILPIT_UI_PORT}"
    export MAILPIT_API_URL
}

launch_demo() {
    local clean_mode="$1"

    prepare_demo_ports
    if [ "$clean_mode" = "clean" ]; then
        "$SCRIPT_DIR/local-dev-down.sh" --clean
    else
        "$SCRIPT_DIR/local-dev-down.sh"
    fi
    "$SCRIPT_DIR/local_demo.sh"
}

case "${1:-}" in
    "")
        launch_demo clean
        ;;
    --clean)
        launch_demo clean
        ;;
    --keep-data)
        launch_demo keep
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
