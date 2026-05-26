#!/usr/bin/env bash
# playwright_local_stack.sh — Start local API + web for Playwright runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_DIR="$REPO_ROOT/.local"
API_LOG_PATH="$LOCAL_DIR/playwright_api.log"
PLAYWRIGHT_API_PORT="${PLAYWRIGHT_API_PORT:-3001}"
DEFAULT_PLAYWRIGHT_API_BASE_URL="http://127.0.0.1:${PLAYWRIGHT_API_PORT}"
API_BASE_URL="${API_BASE_URL:-${API_URL:-$DEFAULT_PLAYWRIGHT_API_BASE_URL}}"
API_URL="${API_URL:-$API_BASE_URL}"
API_HEALTH_URL="${API_BASE_URL%/}/health"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:${PLAYWRIGHT_API_PORT}}"
API_START_TIMEOUT_SECONDS="${PLAYWRIGHT_API_READY_TIMEOUT_SECONDS:-180}"
FORCE_API_RESTART="${PLAYWRIGHT_FORCE_API_RESTART:-0}"
FLAPJACK_URL="${FLAPJACK_URL:-${LOCAL_DEV_FLAPJACK_URL:-http://127.0.0.1:7700}}"
FLAPJACK_HEALTH_URL="${FLAPJACK_URL%/}/health"
FLAPJACK_START_TIMEOUT_SECONDS="${PLAYWRIGHT_FLAPJACK_READY_TIMEOUT_SECONDS:-30}"
FLAPJACK_LOG_PATH="$LOCAL_DIR/playwright_flapjack.log"
FLAPJACK_DATA_DIR="${PLAYWRIGHT_FLAPJACK_DATA_DIR:-$LOCAL_DIR/flapjack-data-playwright}"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"

export PLAYWRIGHT_API_PORT
export API_BASE_URL
export API_URL
export LISTEN_ADDR
load_env_file "$REPO_ROOT/.env.local"
export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"

log() { echo "[playwright_local_stack] $*"; }

if [ "${1:-}" = "--force-api-restart" ]; then
	FORCE_API_RESTART="1"
	shift
fi

mkdir -p "$LOCAL_DIR"

api_pid=""
started_api="0"
flapjack_pid=""
started_flapjack="0"

cleanup() {
	if [ "$started_flapjack" = "1" ] && [ -n "$flapjack_pid" ] && kill -0 "$flapjack_pid" 2>/dev/null; then
		kill "$flapjack_pid" 2>/dev/null || true
		wait "$flapjack_pid" 2>/dev/null || true
	fi
	if [ "$started_api" = "1" ] && [ -n "$api_pid" ] && kill -0 "$api_pid" 2>/dev/null; then
		kill "$api_pid" 2>/dev/null || true
		wait "$api_pid" 2>/dev/null || true
	fi
}

trap cleanup EXIT INT TERM

kill_owned_api_listener_for_restart() {
	local api_hostport api_port listening_pids pid command_line
	api_hostport="$(printf '%s' "$API_HEALTH_URL" | sed -E 's#^https?://([^/]+)/?.*$#\1#')"
	api_port="${api_hostport##*:}"

	if ! [[ "$api_port" =~ ^[0-9]+$ ]]; then
		echo "[playwright_local_stack] ERROR: could not parse API port from API_HEALTH_URL=$API_HEALTH_URL" >&2
		exit 1
	fi

	listening_pids="$(lsof -tiTCP:"$api_port" -sTCP:LISTEN 2>/dev/null || true)"
	if [ -z "$listening_pids" ]; then
		return
	fi

	for pid in $listening_pids; do
		command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
		if [[ "$command_line" == *"fjcloud-api"* ]] || [[ "$command_line" == *"cargo run --manifest-path infra/Cargo.toml -p api"* ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			continue
		fi

		echo "[playwright_local_stack] ERROR: refusing to kill non-fjcloud process on API port $api_port (pid $pid: $command_line)" >&2
		exit 1
	done
}

parse_port_from_http_url() {
	local url="$1"
	local hostport port
	hostport="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/?.*$#\1#')"
	port="${hostport##*:}"

	if ! [[ "$port" =~ ^[0-9]+$ ]]; then
		echo "[playwright_local_stack] ERROR: could not parse port from URL=$url" >&2
		exit 1
	fi

	printf '%s\n' "$port"
}

ensure_local_flapjack_ready() {
	local flapjack_port flapjack_bin listening_pids

	if curl -fsS "$FLAPJACK_HEALTH_URL" >/dev/null 2>&1; then
		return
	fi

	flapjack_port="$(parse_port_from_http_url "$FLAPJACK_HEALTH_URL")"
	listening_pids="$(lsof -tiTCP:"$flapjack_port" -sTCP:LISTEN 2>/dev/null || true)"
	if [ -n "$listening_pids" ]; then
		echo "[playwright_local_stack] ERROR: flapjack health check failed at $FLAPJACK_HEALTH_URL while port $flapjack_port is already in use (pid(s): $listening_pids)" >&2
		echo "[playwright_local_stack] ERROR: stop the stale listener or use a different FLAPJACK_URL before running Playwright." >&2
		exit 1
	fi

	flapjack_bin="$(find_restart_ready_flapjack_binary "${FLAPJACK_DEV_DIR:-}" || true)"
	if [ -z "$flapjack_bin" ] || [ ! -x "$flapjack_bin" ]; then
		echo "[playwright_local_stack] ERROR: flapjack is not healthy at $FLAPJACK_HEALTH_URL and no local flapjack binary was found." >&2
		echo "[playwright_local_stack] ERROR: set FLAPJACK_DEV_DIR to your flapjack_dev checkout and run: cargo build -p flapjack-server" >&2
		exit 1
	fi

	mkdir -p "$FLAPJACK_DATA_DIR"
	FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" \
		nohup "$flapjack_bin" \
			--port "$flapjack_port" \
			--data-dir "$FLAPJACK_DATA_DIR" \
			< /dev/null > "$FLAPJACK_LOG_PATH" 2>&1 &
	flapjack_pid="$!"
	started_flapjack="1"

	if ! wait_for_health "$FLAPJACK_HEALTH_URL" "playwright flapjack" "$FLAPJACK_START_TIMEOUT_SECONDS"; then
		echo "[playwright_local_stack] ERROR: flapjack did not become ready at $FLAPJACK_HEALTH_URL" >&2
		tail -n 200 "$FLAPJACK_LOG_PATH" 2>/dev/null || true
		exit 1
	fi
}

if [ "$FORCE_API_RESTART" = "1" ]; then
	kill_owned_api_listener_for_restart
fi

ensure_local_flapjack_ready

if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
	bash "$SCRIPT_DIR/api-dev.sh" >"$API_LOG_PATH" 2>&1 &
	api_pid="$!"
	started_api="1"

	for _ in $(seq 1 "$API_START_TIMEOUT_SECONDS"); do
		if curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done

	if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
		echo "[playwright_local_stack] ERROR: API did not become ready at $API_HEALTH_URL" >&2
		tail -n 200 "$API_LOG_PATH" 2>/dev/null || true
		exit 1
	fi
fi

exec bash "$SCRIPT_DIR/web-dev.sh" "$@"
