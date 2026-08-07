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
MAILPIT_READY_TIMEOUT_SECONDS="${PLAYWRIGHT_MAILPIT_READY_TIMEOUT_SECONDS:-30}"
PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS="${PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS:-11}"
WEB_PORT_RELEASE_TIMEOUT_SECONDS="${PLAYWRIGHT_WEB_PORT_RELEASE_TIMEOUT_SECONDS:-10}"

require_non_negative_integer_env() {
	local variable_name="$1" value="$2"

	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "[playwright_local_stack] ERROR: $variable_name must be a non-negative integer." >&2
		exit 1
	fi
}

require_non_negative_integer_env PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS \
	"$PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS"
require_non_negative_integer_env PLAYWRIGHT_WEB_PORT_RELEASE_TIMEOUT_SECONDS \
	"$WEB_PORT_RELEASE_TIMEOUT_SECONDS"

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

FLAPJACK_URL="${FLAPJACK_URL:-${LOCAL_DEV_FLAPJACK_URL:-http://127.0.0.1:7700}}"
FLAPJACK_START_TIMEOUT_SECONDS="${PLAYWRIGHT_FLAPJACK_READY_TIMEOUT_SECONDS:-30}"
FLAPJACK_LOG_PATH="$LOCAL_DIR/playwright_flapjack.log"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"
export FJCLOUD_FLAPJACK_VERSION
# shellcheck source=lib/local_stack_contract.sh
source "$SCRIPT_DIR/lib/local_stack_contract.sh"
# shellcheck source=lib/compose_project.sh
source "$SCRIPT_DIR/lib/compose_project.sh"
# shellcheck source=lib/local_url.sh
source "$SCRIPT_DIR/lib/local_url.sh"
# shellcheck source=lib/db_url.sh
source "$SCRIPT_DIR/lib/db_url.sh"
# shellcheck source=lib/local_source_providers.sh
source "$SCRIPT_DIR/lib/local_source_providers.sh"

export COMPOSE_PROJECT_NAME="$(resolve_compose_project_name "$REPO_ROOT")"

configure_loopback_flapjack_url() {
	if ! loopback_http_url_is_valid "$FLAPJACK_URL"; then
		echo "[playwright_local_stack] ERROR: FLAPJACK_URL must be a loopback HTTP URL because the Playwright launcher sends a local admin key to the Flapjack experiments API." >&2
		exit 1
	fi
}

configure_loopback_flapjack_url
FLAPJACK_PORT="$(parse_port_from_http_url "$FLAPJACK_URL")"
FLAPJACK_HEALTH_URL="${FLAPJACK_URL%/}/health"
FLAPJACK_EXPERIMENTS_API_URL="${FLAPJACK_URL%/}/2/abtests"
FLAPJACK_DATA_DIR="${PLAYWRIGHT_FLAPJACK_DATA_DIR:-$LOCAL_DIR/flapjack-data-playwright-$FLAPJACK_PORT}"
FLAPJACK_EXPERIMENTS_DATA_DIR="$FLAPJACK_DATA_DIR/.experiments"

export PLAYWRIGHT_API_PORT
export API_BASE_URL
export API_URL
export LISTEN_ADDR
load_env_file "$REPO_ROOT/.env.local"
REQUIRE_EMAIL_VERIFICATION="${PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION:-0}"
export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"

log() { echo "[playwright_local_stack] $*"; }

mailpit_message_store_json_is_valid() {
	local response_path="$1"

	python3 - "$response_path" <<'PY'
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(payload, dict) or not isinstance(payload.get("messages"), list):
    raise SystemExit(1)
PY
}

configure_loopback_mailpit_api_url() {
	local mailpit_api_url="${MAILPIT_API_URL:-http://127.0.0.1:${LOCAL_MAILPIT_UI_PORT:-8025}}"

	if ! loopback_http_url_is_valid "$mailpit_api_url"; then
		echo "[playwright_local_stack] ERROR: verification-required mode needs a loopback HTTP MAILPIT_API_URL." >&2
		exit 1
	fi

	MAILPIT_API_URL="$mailpit_api_url"
	export MAILPIT_API_URL
}

reject_unknown_api_mode_for_email_verification() {
	if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
		return
	fi

	echo "[playwright_local_stack] ERROR: verification-required mode cannot reuse the already-healthy API at $API_BASE_URL because its email configuration is unknown." >&2
	echo "[playwright_local_stack] ERROR: re-run with --force-api-restart to replace an owned local API with verification-safe settings." >&2
	exit 1
}

ensure_mailpit_ready_for_email_verification() {
	local response_file running_services elapsed=0
	COMPOSE_PROJECT_NAME="$(resolve_compose_project_name "$REPO_ROOT")"
	export COMPOSE_PROJECT_NAME

	if ! running_services="$(
		cd "$REPO_ROOT" &&
			docker compose ps --status running --services mailpit 2>&1
	)"; then
		echo "[playwright_local_stack] ERROR: could not determine whether Mailpit is already running; refusing to claim ownership." >&2
		printf '%s\n' "$running_services" | sed 's/^/[playwright_local_stack]   /' >&2
		exit 1
	fi
	if printf '%s\n' "$running_services" | grep -Fxq "mailpit"; then
		log "Using the already-running Mailpit service..."
	else
		log "Starting Mailpit for verification-required Playwright stack..."
		started_mailpit="1"
		(cd "$REPO_ROOT" && docker compose up -d mailpit) 2>&1 |
			while IFS= read -r line; do log "$line"; done
	fi

	response_file="$(mktemp "$LOCAL_DIR/mailpit-messages.XXXXXX")"
	while [ "$elapsed" -lt "$MAILPIT_READY_TIMEOUT_SECONDS" ]; do
		if curl -fsS "${MAILPIT_API_URL%/}/api/v1/messages" -o "$response_file" &&
			mailpit_message_store_json_is_valid "$response_file"; then
			rm -f "$response_file"
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	echo "[playwright_local_stack] ERROR: Mailpit did not expose valid message-store JSON at ${MAILPIT_API_URL%/}/api/v1/messages" >&2
	cat "$response_file" >&2 2>/dev/null || true
	rm -f "$response_file"
	exit 1
}

configure_email_verification_mode() {
	if [ "$REQUIRE_EMAIL_VERIFICATION" = "1" ]; then
		unset SKIP_EMAIL_VERIFICATION
		unset API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION
		configure_loopback_mailpit_api_url
		reject_unknown_api_mode_for_email_verification
		ensure_mailpit_ready_for_email_verification
		return
	fi

	export SKIP_EMAIL_VERIFICATION="1"
	export API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION="1"
}

require_local_database_url() {
	local database_host
	[ -n "${DATABASE_URL:-}" ] || {
		echo "[playwright_local_stack] ERROR: DATABASE_URL is required before applying local Playwright migrations." >&2
		exit 1
	}

	database_host="$(python3 - "$DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
        raise ValueError
except (TypeError, ValueError):
    raise SystemExit(1)

print(parsed.hostname.lower())
PY
	)" || {
		echo "[playwright_local_stack] ERROR: DATABASE_URL must be a valid PostgreSQL URL before applying local Playwright migrations." >&2
		exit 1
	}

	case "$database_host" in
		localhost|127.0.0.1|::1) ;;
		*)
			echo "[playwright_local_stack] ERROR: refusing to apply local Playwright migrations to a non-loopback DATABASE_URL." >&2
			exit 1
			;;
	esac
}

reconcile_playwright_bootstrap_admin_user() {
	local admin_key credential_prefix credential_sha256 reconciled_identifier
	local db_host db_port db_user db_password db_name
	admin_key="${ADMIN_KEY:-}"
	if [ -z "$admin_key" ]; then
		echo "[playwright_local_stack] ERROR: ADMIN_KEY is required before reconciling local Playwright admin credentials." >&2
		exit 1
	fi

	credential_prefix="${admin_key:0:16}"
	credential_sha256="$(
		printf '%s' "$admin_key" |
			python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
	)"

	db_host="$(require_db_url_part "$DATABASE_URL" db_url_host)"
	db_port="$(require_db_url_part "$DATABASE_URL" db_url_port)"
	db_user="$(require_db_url_part "$DATABASE_URL" db_url_user)"
	db_password="$(db_url_password "$DATABASE_URL")"
	db_name="$(require_db_url_part "$DATABASE_URL" db_url_database)"

	# An UPDATE that matches nothing is not automatically a problem, so the statement
	# reports which of the three real cases it hit rather than just succeeding:
	#
	#   reconciled                 the single bootstrap row now holds this ADMIN_KEY
	#   empty-api-will-bootstrap   admin_users is empty; api-dev's
	#                              bootstrap_admin_user_if_empty (infra/api/src/auth/admin.rs)
	#                              inserts the row from the same ADMIN_KEY at startup
	#   unreconciled               rows exist but none was rewritten — an extra admin row,
	#                              or a row another stack repointed at its own key
	#
	# Only the last is fatal, and it is fatal precisely because it is invisible later: the
	# API boots holding an ADMIN_KEY the database does not have and 401s every
	# admin-authenticated request. That has already cost one run 37 of its 50 browser-test
	# failures, diagnosed hours from this line.
	#
	# -At is unaligned/tuples-only so the result is the bare token. Assigned separately
	# from `local` so `set -e` still sees a psql failure; `local x="$(...)"` masks it.
	reconciled_identifier="$(
		PGHOST="$db_host" \
			PGPORT="$db_port" \
			PGUSER="$db_user" \
			PGPASSWORD="$db_password" \
			PGDATABASE="$db_name" \
			psql \
			-At \
			-v ON_ERROR_STOP=1 \
			-v credential_prefix="$credential_prefix" \
			-v credential_sha256="$credential_sha256" <<'SQL'
WITH reconciled AS (
    UPDATE admin_users
    SET credential_prefix = :'credential_prefix',
        credential_sha256 = :'credential_sha256',
        revoked_at = NULL
    WHERE identifier = 'bootstrap-admin-key'
      AND (SELECT COUNT(*) FROM admin_users) = 1
    RETURNING identifier
)
SELECT CASE
    WHEN EXISTS (SELECT 1 FROM reconciled) THEN 'reconciled'
    WHEN NOT EXISTS (SELECT 1 FROM admin_users) THEN 'empty-api-will-bootstrap'
    ELSE 'unreconciled'
END;
SQL
	)"

	# Anything other than the two known-good tokens is treated as failure, so a psql that
	# returns nothing at all cannot read as healthy either.
	case "$reconciled_identifier" in
	reconciled | empty-api-will-bootstrap) ;;
	*)
		echo "[playwright_local_stack] ERROR: bootstrap-admin credential reconciliation left the persisted admin row out of sync (state: ${reconciled_identifier:-no-result}), so the API would reject the configured ADMIN_KEY on every admin request." >&2
		echo "[playwright_local_stack] ERROR: expected admin_users to be empty or to hold exactly one row identified as 'bootstrap-admin-key'; re-seed the local database before running Playwright." >&2
		exit 1
		;;
	esac
}

if [ "${1:-}" = "--force-api-restart" ]; then
	FORCE_API_RESTART="1"
	shift
fi

mkdir -p "$LOCAL_DIR"

api_pid=""
started_api="0"
flapjack_bin=""
flapjack_pid=""
started_flapjack="0"
web_pid=""
started_web="0"
started_mailpit="0"

cleanup() {
	local preserved_status="${1:-$?}"
	local cleanup_failed=0

	if [ "$started_web" = "1" ] && [ -n "$web_pid" ] && kill -0 "$web_pid" 2>/dev/null; then
		kill "$web_pid" 2>/dev/null || true
		wait "$web_pid" 2>/dev/null || true
	fi
	if [ "$started_flapjack" = "1" ] && [ -n "$flapjack_pid" ] && kill -0 "$flapjack_pid" 2>/dev/null; then
		kill "$flapjack_pid" 2>/dev/null || true
		wait "$flapjack_pid" 2>/dev/null || true
	fi
	if [ "$started_api" = "1" ] && [ -n "$api_pid" ] && kill -0 "$api_pid" 2>/dev/null; then
		kill "$api_pid" 2>/dev/null || true
		wait "$api_pid" 2>/dev/null || true
	fi
	if [ "$started_mailpit" = "1" ]; then
		started_mailpit="0"
		(cd "$REPO_ROOT" && docker compose stop mailpit) 2>&1 |
			while IFS= read -r line; do log "$line"; done || true
	fi
	if source_provider_stack_owned; then
		source_provider_teardown_owned_stack "scripts/playwright_local_stack.sh" 2>&1 |
			while IFS= read -r line; do log "$line"; done || cleanup_failed=1
	fi

	if [ "$cleanup_failed" = "1" ]; then
		return 1
	fi

	return "$preserved_status"
}

handle_shutdown() {
	trap - EXIT
	cleanup 0 || exit 1
	exit 0
}
trap cleanup EXIT
trap handle_shutdown INT TERM

# Playwright local stack restart reclaims only listeners this workspace owns.
# API and web holders share the same fail-closed contract: TERM the repo-owned
# dev process, but name the pid/command and exit for any foreign listener.
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
		if [[ "$command_line" == *"fjcloud-api"* ]] || \
			[[ "$command_line" == *"cargo run --manifest-path infra/Cargo.toml -p api"* ]] || \
			[[ "$command_line" == *"cargo run -p api --manifest-path infra/Cargo.toml"* ]] || \
			[[ "$command_line" == *"/target/debug/api"* ]] || \
			[[ "$command_line" == *"/target/release/api"* ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			continue
		fi

		echo "[playwright_local_stack] ERROR: refusing to kill non-fjcloud process on API port $api_port (pid $pid: $command_line)" >&2
		exit 1
	done
}

resolve_playwright_web_port_for_restart() {
	local arg derived_web_port

	# Runtime owner order: web/playwright.config.ts passes --port for spawned
	# local-stack runs; PLAYWRIGHT_WEB_PORT and the TS-contract mirror only cover
	# direct/manual invocations of this shell script.
	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
			--port)
				shift
				if [ "$#" -eq 0 ]; then
					echo "[playwright_local_stack] ERROR: --port requires a value." >&2
					exit 1
				fi
				printf '%s\n' "$1"
				return
				;;
			--port=*)
				printf '%s\n' "${arg#--port=}"
				return
				;;
		esac
		shift
	done

	if [ -n "${PLAYWRIGHT_WEB_PORT:-}" ]; then
		printf '%s\n' "$PLAYWRIGHT_WEB_PORT"
		return
	fi

	# shellcheck source=lib/playwright_port_plan.sh
	source "$SCRIPT_DIR/lib/playwright_port_plan.sh"
	# web/playwright.config.ts resolves the web port from its own working
	# directory, so hash <repo>/web here. Hashing $REPO_ROOT instead yields the
	# manual stack's Meilisearch host port — a port the web server never binds.
	derived_web_port="$(playwright_derive_web_port "$REPO_ROOT" "$REPO_ROOT/web")" || {
		echo "[playwright_local_stack] ERROR: could not derive Playwright web port from web/playwright.config.contract.ts" >&2
		exit 1
	}
	printf '%s\n' "$derived_web_port"
}

# Mirrors parsePlaywrightWebPort in web/playwright.config.contract.ts, which
# rejects the same values before Playwright ever spawns this script.
validate_playwright_web_port_for_restart() {
	local web_port="$1"

	if ! [[ "$web_port" =~ ^[0-9]+$ ]]; then
		echo "[playwright_local_stack] ERROR: could not parse Playwright web port=$web_port" >&2
		exit 1
	fi
	if [ "$web_port" -lt 1024 ] || [ "$web_port" -gt 65535 ]; then
		echo "[playwright_local_stack] ERROR: Playwright web port must be between 1024 and 65535 (received $web_port)" >&2
		exit 1
	fi
}

playwright_web_start_args_include_port() {
	local arg

	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
			--port)
				return 0
				;;
			--port=*)
				return 0
				;;
		esac
		shift
	done
	return 1
}

# Whole-token argv matching: a candidate only matches when it is bounded by the
# start/end of the command line or by a space. Without those boundaries `npm run
# developer` and `.../.bin/vite-helper` would be accepted as owned web servers.
argv_starts_with_tokens() {
	local command_line="$1" tokens="$2"

	[[ "$command_line" == "$tokens" ]] || [[ "$command_line" == "$tokens "* ]]
}

argv_contains_token() {
	local command_line="$1" token="$2"

	argv_starts_with_tokens "$command_line" "$token" || \
		[[ "$command_line" == *" $token" ]] || \
		[[ "$command_line" == *" $token "* ]]
}

command_line_is_owned_npm_web_server() {
	local command_line="$1" pid="$2" web_port="$3" process_cwd

	argv_starts_with_tokens "$command_line" "npm run dev" || return 1
	[[ " $command_line " == *" --port $web_port "* ]] || \
		[[ " $command_line " == *" --port=$web_port "* ]] || \
		return 1

	process_cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)"
	[[ "$process_cwd" == "$REPO_ROOT/web" ]]
}

process_is_owned_web_server() {
	local command_line="$1" pid="$2" web_port="$3"

	argv_contains_token "$command_line" "$REPO_ROOT/web/node_modules/.bin/vite" || \
		argv_contains_token "$command_line" "$REPO_ROOT/web/node_modules/vite/bin/vite.js" || \
		command_line_is_owned_npm_web_server "$command_line" "$pid" "$web_port"
}

# TERM only asks; the stale web server still owns the listening socket until it
# actually exits, and the web server spawned right after this binds with
# --strictPort. `wait` cannot cover the gap — the reclaimed holder is not a child
# of this shell, so `wait <pid>` returns immediately — so poll the listener probe
# instead and fail closed rather than hand a busy port to a strict-port bind.
wait_for_web_port_release() {
	local web_port="$1" reclaimed_pids="$2" attempt pid
	local attempts=$((WEB_PORT_RELEASE_TIMEOUT_SECONDS * 10))

	for ((attempt = 0; attempt <= attempts; attempt++)); do
		if [ -z "$(lsof -tiTCP:"$web_port" -sTCP:LISTEN 2>/dev/null || true)" ]; then
			return
		fi
		sleep 0.1
	done

	echo "[playwright_local_stack] ERROR: web port $web_port is still held ${WEB_PORT_RELEASE_TIMEOUT_SECONDS}s after TERM; refusing to start the web server on a busy strict port" >&2
	for pid in $reclaimed_pids; do
		echo "[playwright_local_stack] ERROR: reclaimed web port holder pid $pid did not release web port $web_port" >&2
	done
	exit 1
}

kill_owned_web_listener_for_restart() {
	local web_port="$1" listening_pids pid command_line owned_pids=""

	listening_pids="$(lsof -tiTCP:"$web_port" -sTCP:LISTEN 2>/dev/null || true)"
	if [ -z "$listening_pids" ]; then
		return
	fi

	# Classify the whole listener set before terminating any of it: a foreign
	# holder anywhere in the set must refuse the reclaim without killing a
	# process, whichever order lsof reports the pids in.
	for pid in $listening_pids; do
		command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
		if ! process_is_owned_web_server "$command_line" "$pid" "$web_port"; then
			echo "[playwright_local_stack] ERROR: refusing to kill non-fjcloud process on web port $web_port (pid $pid: $command_line)" >&2
			exit 1
		fi
		owned_pids+="${owned_pids:+ }$pid"
	done

	for pid in $owned_pids; do
		kill "$pid" 2>/dev/null || true
	done
	wait_for_web_port_release "$web_port" "$owned_pids"
}

reset_playwright_experiments_storage() {
	# The Playwright stack owns this hidden Flapjack system index. Rebuilding it
	# avoids stale Tantivy metadata from an interrupted prior local browser run.
	rm -rf "$FLAPJACK_EXPERIMENTS_DATA_DIR"
}

ensure_flapjack_experiments_api_ready() {
	local response_file http_status
	response_file="$(mktemp "$LOCAL_DIR/flapjack-experiments-bootstrap.XXXXXX")"
	http_status="$(
		curl -sS -o "$response_file" -w '%{http_code}' \
			-X GET "$FLAPJACK_EXPERIMENTS_API_URL" \
			-H "X-Algolia-Application-Id: flapjack" \
			-H "X-Algolia-API-Key: ${FLAPJACK_ADMIN_KEY}"
	)" || {
		echo "[playwright_local_stack] ERROR: failed to verify Flapjack experiments API readiness" >&2
		cat "$response_file" >&2 2>/dev/null || true
		rm -f "$response_file"
		exit 1
	}

	case "$http_status" in
		200)
			rm -f "$response_file"
			;;
		*)
			echo "[playwright_local_stack] ERROR: experiments API readiness returned HTTP $http_status" >&2
			cat "$response_file" >&2 2>/dev/null || true
			rm -f "$response_file"
			exit 1
			;;
	esac
}

ensure_local_flapjack_ready() {
	local listening_pids resolution_status=0

	flapjack_bin="$(find_restart_ready_flapjack_binary "${FLAPJACK_DEV_DIR:-}")" || resolution_status=$?
	if [ "$resolution_status" -eq "$FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS" ]; then
		echo "[playwright_local_stack] ERROR: selected FLAPJACK_DEV_DIR source build or provenance validation failed." >&2
		exit 1
	fi
	if [ -n "$flapjack_bin" ] && [ -x "$flapjack_bin" ]; then
		flapjack_export_required_artifact_identity "$flapjack_bin" || {
			echo "[playwright_local_stack] ERROR: failed to derive required Flapjack artifact identity from selected binary: $flapjack_bin" >&2
			exit 1
		}
	fi
	if curl -fsS "$FLAPJACK_HEALTH_URL" >/dev/null 2>&1; then
		if [ -n "$flapjack_bin" ]; then
			echo "[playwright_local_stack] Flapjack provenance: $(flapjack_source_provenance_summary)"
		elif ! flapjack_required_runtime_identity_evidence_available; then
			echo "[playwright_local_stack] ERROR: Flapjack at $FLAPJACK_URL is healthy but has no selected local Flapjack binary and no exact required identity evidence." >&2
			echo "[playwright_local_stack] ERROR: set FLAPJACK_DEV_DIR to your pinned flapjack_dev checkout or export FJCLOUD_FLAPJACK_REQUIRED_REVISION, FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID, and FJCLOUD_FLAPJACK_REQUIRED_SHA256 before running Playwright." >&2
			exit 1
		fi
		return
	fi

	listening_pids="$(lsof -tiTCP:"$FLAPJACK_PORT" -sTCP:LISTEN 2>/dev/null || true)"
	if [ -n "$listening_pids" ]; then
		echo "[playwright_local_stack] ERROR: flapjack health check failed at $FLAPJACK_HEALTH_URL while port $FLAPJACK_PORT is already in use (pid(s): $listening_pids)" >&2
		echo "[playwright_local_stack] ERROR: stop the stale listener or use a different FLAPJACK_URL before running Playwright." >&2
		exit 1
	fi

	if [ -z "$flapjack_bin" ] || [ ! -x "$flapjack_bin" ]; then
		echo "[playwright_local_stack] ERROR: flapjack is not healthy at $FLAPJACK_HEALTH_URL and no local flapjack binary was found." >&2
		echo "[playwright_local_stack] ERROR: set FLAPJACK_DEV_DIR to your flapjack_dev checkout and run: cargo build -p flapjack-server" >&2
		exit 1
	fi
	echo "[playwright_local_stack] Flapjack provenance: $(flapjack_source_provenance_summary)"

	mkdir -p "$FLAPJACK_DATA_DIR"
	reset_playwright_experiments_storage
	FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" \
		nohup "$flapjack_bin" \
			--port "$FLAPJACK_PORT" \
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

selected_flapjack_runtime_identity_missing_vars() {
	local missing_vars=""

	[ -n "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" ] || missing_vars="${missing_vars:+$missing_vars }FJCLOUD_FLAPJACK_REQUIRED_REVISION"
	[ -n "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" ] || missing_vars="${missing_vars:+$missing_vars }FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID"
	[ -n "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" ] || missing_vars="${missing_vars:+$missing_vars }FJCLOUD_FLAPJACK_REQUIRED_SHA256"

	printf '%s\n' "$missing_vars"
}

export_selected_flapjack_runtime_identity_or_exit() {
	local export_status=0 missing_vars

	[ -n "$flapjack_bin" ] || return 0
	flapjack_export_required_runtime_identity "$flapjack_bin" || export_status=$?
	missing_vars="$(selected_flapjack_runtime_identity_missing_vars)"
	if [ "$export_status" -ne 0 ] || [ -n "$missing_vars" ]; then
		[ -n "$missing_vars" ] || \
			missing_vars="FJCLOUD_FLAPJACK_REQUIRED_REVISION FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID FJCLOUD_FLAPJACK_REQUIRED_SHA256"
		echo "[playwright_local_stack] ERROR: incomplete selected Flapjack runtime identity: $missing_vars" >&2
		exit 1
	fi
}

if source_provider_profile_enabled; then
	log "Arranging source providers for provider-parity Playwright."
	source_provider_start_and_seed \
		"$REPO_ROOT" \
		"${LOCAL_MEILISEARCH_PORT:?LOCAL_MEILISEARCH_PORT is required for provider parity}" \
		"${LOCAL_TYPESENSE_PORT:?LOCAL_TYPESENSE_PORT is required for provider parity}" \
		"${SOURCE_PROVIDER_HEALTH_TIMEOUT_SECONDS:-60}" || {
		echo "[playwright_local_stack] ERROR: source providers failed startup, readiness, or fixture capture." >&2
		exit 1
	}
fi

if [ "$FORCE_API_RESTART" = "1" ]; then
	kill_owned_api_listener_for_restart
fi

configure_email_verification_mode

if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then require_local_database_url; fi
ensure_local_flapjack_ready
flapjack_identity_reason="$(flapjack_runtime_identity_reason "$FLAPJACK_URL" "$started_flapjack")"
if [ "$flapjack_identity_reason" != "match" ]; then
	flapjack_identity_rejection_message \
		"$flapjack_identity_reason" "$FLAPJACK_URL" "${flapjack_bin:-}" >&2
	echo "[playwright_local_stack] ERROR: refusing to run the browser suite against an engine fjcloud did not accept." >&2
	exit 1
fi
export_selected_flapjack_runtime_identity_or_exit
ensure_flapjack_experiments_api_ready

if ! curl -fsS "$API_HEALTH_URL" >/dev/null 2>&1; then
	require_local_database_url
	bash "$SCRIPT_DIR/local-dev-migrate.sh"
	reconcile_playwright_bootstrap_admin_user
	if [ "$REQUIRE_EMAIL_VERIFICATION" = "1" ]; then
		# api-dev.sh owns revoking the auto-verify and SES escape hatches after it
		# reloads .env.local; clearing them only here would not survive that reload.
		env -u SKIP_EMAIL_VERIFICATION -u API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION \
			FJCLOUD_FLAPJACK_VERSION="$FJCLOUD_FLAPJACK_VERSION" \
			API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 \
			MAILPIT_API_URL="$MAILPIT_API_URL" \
			bash "$SCRIPT_DIR/api-dev.sh" >"$API_LOG_PATH" 2>&1 &
	else
		FJCLOUD_FLAPJACK_VERSION="$FJCLOUD_FLAPJACK_VERSION" \
		SKIP_EMAIL_VERIFICATION="$SKIP_EMAIL_VERIFICATION" \
			API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION="$API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION" \
			bash "$SCRIPT_DIR/api-dev.sh" >"$API_LOG_PATH" 2>&1 &
	fi
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

if ! api_supports_capability "$API_BASE_URL" "$FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY"; then
	echo "[playwright_local_stack] ERROR: API at $API_BASE_URL is live but does not advertise $FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY." >&2
	echo "[playwright_local_stack] ERROR: restart the API from this checkout before running Playwright." >&2
	exit 1
fi

if ! api_public_infrastructure_is_ready "$API_BASE_URL"; then
	echo "[playwright_local_stack] ERROR: API public infrastructure route is not ready for Playwright." >&2
	exit 1
fi
# The readiness GET populates the API's ten-second in-memory public
# infrastructure cache before Playwright fixtures seed their VM canary. Leave a
# one-second margin so the first browser request recomputes from the seeded DB.
if [ "$PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS" -gt 0 ]; then
	log "Waiting ${PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS}s for the public infrastructure readiness cache to expire."
	sleep "$PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS"
fi

web_port="$(resolve_playwright_web_port_for_restart "$@")"
validate_playwright_web_port_for_restart "$web_port"
kill_owned_web_listener_for_restart "$web_port"
web_start_args=("$@")
if ! playwright_web_start_args_include_port "$@"; then
	web_start_args+=(--port "$web_port")
fi
bash "$SCRIPT_DIR/web-dev.sh" "${web_start_args[@]}" &
web_pid="$!"
started_web="1"

set +e
wait "$web_pid"
web_status="$?"
set -e
started_web="0"
exit "$web_status"
