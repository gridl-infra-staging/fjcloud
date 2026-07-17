#!/usr/bin/env bash
# metering_breaker_target_failure.sh — prepared-local-stack chaos proof for metering breaker alerts.
#
# Proof flow:
# 1) fail-closed preflight: local stack prepared + single loopback webhook channel
# 2) start isolated loopback fake metrics endpoint and webhook receiver
# 3) run metering-agent against fake metrics target
# 4) wait for first successful scrape
# 5) force failure by killing only the fake-metrics PID from this script's pid file
# 6) wait for exactly one breaker-open alert payload and assert SSOT metadata fields

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/health.sh
source "$REPO_ROOT/scripts/lib/health.sh"

log() { echo "[metering-breaker-proof] $*"; }
error() { echo "[metering-breaker-proof] ERROR: $*" >&2; }

usage() {
    cat >&2 <<'EOF'
Usage: metering_breaker_target_failure.sh

Requires exactly one local loopback webhook URL configured:
  - SLACK_WEBHOOK_URL=http://127.0.0.1:<port>/<path>
  - OR DISCORD_WEBHOOK_URL=http://127.0.0.1:<port>/<path>
EOF
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || {
        finalize_failure "Missing required dependency: $command_name"
    }
}

iso_utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

allocate_loopback_port() {
    python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

is_loopback_url() {
    local url="$1"

    python3 - "$url" <<'PY'
import ipaddress
import sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()
parsed = urlparse(raw)
if parsed.scheme != "http":
    raise SystemExit(1)
if parsed.username or parsed.password:
    raise SystemExit(1)
if not parsed.hostname:
    raise SystemExit(1)

host = parsed.hostname
if host == "localhost":
    raise SystemExit(0)

try:
    ip = ipaddress.ip_address(host)
except ValueError:
    raise SystemExit(1)

if not ip.is_loopback:
    raise SystemExit(1)
PY
}

parse_loopback_url() {
    local url="$1"

    python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
if not parsed.hostname:
    raise SystemExit(1)
scheme = parsed.scheme
port = parsed.port
if port is None:
    port = 80 if scheme == "http" else 443
path = parsed.path or "/"
print(f"{parsed.hostname}\t{port}\t{path}")
PY
}

ensure_summary_json() {
    jq -n \
        --arg status "$RUN_STATUS" \
        --arg started_at "$STARTED_AT" \
        --arg finished_at "$FINISHED_AT" \
        --arg reason "$SUMMARY_REASON" \
        --arg artifacts_dir "$ARTIFACT_DIR" \
        --arg webhook_channel "$WEBHOOK_CHANNEL" \
        --arg webhook_url "$WEBHOOK_URL" \
        --arg fake_metrics_url "$FAKE_METRICS_URL" \
        --arg first_successful_scrape_at "$FIRST_SUCCESSFUL_SCRAPE_AT" \
        --arg metrics_requests_before_kill "$METRICS_REQUESTS_BEFORE_KILL" \
        --arg forced_failure_at "$FORCED_FAILURE_AT" \
        --arg forced_failure_pid "$FORCED_FAILURE_PID" \
        --arg captured_alert_count "$CAPTURED_ALERT_COUNT" \
        --arg metadata_assertions_passed "$METADATA_ASSERTIONS_PASSED" \
        --arg metering_log "$METERING_AGENT_LOG_FILE" \
        --arg local_stack_preflight "$LOCAL_STACK_PREFLIGHT" \
        --arg prepared_local_stack "$PREPARED_LOCAL_STACK" \
        --arg fake_metrics_pid "$FAKE_METRICS_PID" \
        '{
            status: $status,
            started_at: $started_at,
            finished_at: $finished_at,
            reason: $reason,
            artifacts_dir: $artifacts_dir,
            preflight: {
                prepared_local_stack: ($prepared_local_stack == "true"),
                local_stack_preflight: $local_stack_preflight
            },
            webhook_channel: $webhook_channel,
            webhook_url: $webhook_url,
            fake_metrics: {
                url: $fake_metrics_url,
                pid: ($fake_metrics_pid | tonumber? // null)
            },
            first_successful_scrape_at: $first_successful_scrape_at,
            metrics_requests_before_kill: ($metrics_requests_before_kill | tonumber? // 0),
            forced_failure: {
                killed_at: $forced_failure_at,
                killed_pid: ($forced_failure_pid | tonumber? // null)
            },
            captured_alert_count: ($captured_alert_count | tonumber? // 0),
            metadata_assertions_passed: ($metadata_assertions_passed == "true"),
            metering_log: $metering_log
        }' > "$ARTIFACT_DIR/summary.json"
}

ensure_summary_md() {
    cat > "$ARTIFACT_DIR/summary.md" <<EOF
# Metering Breaker Target Failure Proof

- status: ${RUN_STATUS}
- started_at: ${STARTED_AT}
- finished_at: ${FINISHED_AT}
- reason: ${SUMMARY_REASON}
- artifacts_dir: ${ARTIFACT_DIR}
- webhook_channel: ${WEBHOOK_CHANNEL}
- webhook_url: ${WEBHOOK_URL}
- fake_metrics_url: ${FAKE_METRICS_URL}
- fake_metrics_pid: ${FAKE_METRICS_PID}
- first_successful_scrape_at: ${FIRST_SUCCESSFUL_SCRAPE_AT}
- metrics_requests_before_kill: ${METRICS_REQUESTS_BEFORE_KILL}
- forced_failure_at: ${FORCED_FAILURE_AT}
- forced_failure_pid: ${FORCED_FAILURE_PID}
- captured_alert_count: ${CAPTURED_ALERT_COUNT}
- metadata_assertions_passed: ${METADATA_ASSERTIONS_PASSED}
- metering_log: ${METERING_AGENT_LOG_FILE}
EOF
}

finalize_failure() {
    local message="$1"
    SUMMARY_REASON="$message"
    RUN_STATUS="failed"
    FINISHED_AT="$(iso_utc_now)"
    ensure_summary_json
    ensure_summary_md
    error "$message"
    log "Artifacts: $ARTIFACT_DIR"
    exit 1
}

finalize_success() {
    local message="$1"
    SUMMARY_REASON="$message"
    RUN_STATUS="passed"
    FINISHED_AT="$(iso_utc_now)"
    ensure_summary_json
    ensure_summary_md
    log "$message"
    log "Artifacts: $ARTIFACT_DIR"
}

read_count_file() {
    local count_file="$1"
    local raw

    raw="$(cat "$count_file" 2>/dev/null || true)"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$raw"
        return 0
    fi
    printf '0\n'
}

kill_pid_if_live() {
    local pid_file="$1"
    local label="$2"
    local pid

    [ -f "$pid_file" ] || return 0
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        log "stopped ${label} (PID ${pid})"
    fi
}

cleanup() {
    kill_pid_if_live "$METERING_AGENT_PID_FILE" "metering-agent"
    kill_pid_if_live "$WEBHOOK_RECEIVER_PID_FILE" "webhook receiver"
    kill_pid_if_live "$FAKE_METRICS_PID_FILE" "fake metrics endpoint"
}

resolve_shared_customer_id() {
    local customer_id

    if command -v psql >/dev/null 2>&1; then
        customer_id="$(PSQLRC=/dev/null psql "$DATABASE_URL" -tAc \
            "SELECT id FROM customers WHERE billing_plan = 'shared' LIMIT 1" 2>/dev/null || true)"
    elif command -v docker >/dev/null 2>&1 \
        && (cd "$REPO_ROOT" && docker compose ps --status running postgres >/dev/null 2>&1); then
        customer_id="$(cd "$REPO_ROOT" && docker compose exec -T postgres \
            psql -U griddle -d fjcloud_dev -tAc \
            "SELECT id FROM customers WHERE billing_plan = 'shared' LIMIT 1" 2>/dev/null || true)"
    else
        finalize_failure "Prepared local stack prerequisite missing: cannot query shared customer (psql unavailable and Docker Postgres fallback unavailable). Run scripts/local-dev-up.sh then scripts/seed_local.sh."
    fi

    customer_id="$(echo "$customer_id" | tr -d '[:space:]')"
    if [ -z "$customer_id" ]; then
        finalize_failure "Prepared local stack prerequisite missing: no shared customer found in local DB. Run scripts/local-dev-up.sh then scripts/seed_local.sh."
    fi
    CUSTOMER_ID="$customer_id"
}

resolve_webhook_channel_config() {
    local slack_set=0
    local discord_set=0

    [ -n "${SLACK_WEBHOOK_URL:-}" ] && slack_set=1
    [ -n "${DISCORD_WEBHOOK_URL:-}" ] && discord_set=1

    if [ "$((slack_set + discord_set))" -ne 1 ]; then
        finalize_failure "exactly one of SLACK_WEBHOOK_URL or DISCORD_WEBHOOK_URL must be configured for this single-capture proof."
    fi

    if [ "$slack_set" -eq 1 ]; then
        WEBHOOK_CHANNEL="slack"
        WEBHOOK_URL="$SLACK_WEBHOOK_URL"
    else
        WEBHOOK_CHANNEL="discord"
        WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
    fi

    if ! is_loopback_url "$WEBHOOK_URL"; then
        finalize_failure "Configured webhook URL must be loopback-only for local chaos proof: $WEBHOOK_URL"
    fi
}

preflight_local_stack() {
    if [ ! -f "$REPO_ROOT/.env.local" ]; then
        finalize_failure "Prepared local stack prerequisite missing: .env.local not found. Run scripts/local-dev-up.sh then scripts/seed_local.sh."
    fi

    load_env_file "$REPO_ROOT/.env.local"
    [ -n "${DATABASE_URL:-}" ] \
        || finalize_failure "Prepared local stack prerequisite missing: DATABASE_URL is required in .env.local. Run scripts/local-dev-up.sh then scripts/seed_local.sh."

    resolve_shared_customer_id
    resolve_webhook_channel_config

    PREPARED_LOCAL_STACK=true
    LOCAL_STACK_PREFLIGHT="passed"
    log "local stack preflight passed (shared customer: $CUSTOMER_ID; webhook channel: $WEBHOOK_CHANNEL)"
}

start_fake_metrics_endpoint() {
    local metrics_host="127.0.0.1"
    local metrics_port
    metrics_port="$(allocate_loopback_port)"
    FAKE_METRICS_URL="http://${metrics_host}:${metrics_port}"

    if ! is_loopback_url "$FAKE_METRICS_URL"; then
        finalize_failure "Fake metrics endpoint must resolve to loopback only: $FAKE_METRICS_URL"
    fi

    cat > "$FAKE_METRICS_PAYLOAD_FILE" <<'EOF'
# TYPE flapjack_search_requests_total counter
flapjack_search_requests_total{index="products"} 42
EOF
    printf '0\n' > "$FAKE_METRICS_REQUEST_COUNT_FILE"

    python3 - "$metrics_host" "$metrics_port" "$FAKE_METRICS_PAYLOAD_FILE" "$FAKE_METRICS_REQUEST_COUNT_FILE" <<'PY' &
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host = sys.argv[1]
port = int(sys.argv[2])
payload_path = pathlib.Path(sys.argv[3])
count_path = pathlib.Path(sys.argv[4])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        try:
            count = int(count_path.read_text(encoding="utf-8").strip() or "0")
        except Exception:
            count = 0
        count_path.write_text(f"{count + 1}\n", encoding="utf-8")

        body = payload_path.read_text(encoding="utf-8").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _fmt, *_args):
        return

server = ThreadingHTTPServer((host, port), Handler)
server.serve_forever()
PY
    FAKE_METRICS_PID="$!"
    echo "$FAKE_METRICS_PID" > "$FAKE_METRICS_PID_FILE"

    wait_for_health "${FAKE_METRICS_URL}/health" "fake metrics endpoint" 10 \
        || finalize_failure "Fake metrics endpoint failed health check at ${FAKE_METRICS_URL}/health"
    log "started fake metrics endpoint at $FAKE_METRICS_URL (PID $FAKE_METRICS_PID)"
}

start_webhook_receiver() {
    local parsed
    parsed="$(parse_loopback_url "$WEBHOOK_URL" 2>/dev/null || true)"
    [ -n "$parsed" ] || finalize_failure "Configured webhook URL could not be parsed: $WEBHOOK_URL"

    WEBHOOK_HOST="$(printf '%s\n' "$parsed" | cut -f1)"
    WEBHOOK_PORT="$(printf '%s\n' "$parsed" | cut -f2)"
    WEBHOOK_PATH="$(printf '%s\n' "$parsed" | cut -f3)"
    [ -n "$WEBHOOK_PATH" ] || WEBHOOK_PATH="/"

    python3 - "$WEBHOOK_HOST" "$WEBHOOK_PORT" "$WEBHOOK_PATH" "$ARTIFACT_DIR" <<'PY' &
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host = sys.argv[1]
port = int(sys.argv[2])
expected_path = sys.argv[3]
artifact_dir = pathlib.Path(sys.argv[4])
counter = {"value": 0}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != expected_path:
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        counter["value"] += 1
        payload_path = artifact_dir / f"webhook_payload_{counter['value']}.json"
        payload_path.write_bytes(body)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, _fmt, *_args):
        return

server = ThreadingHTTPServer((host, port), Handler)
server.serve_forever()
PY
    WEBHOOK_RECEIVER_PID="$!"
    echo "$WEBHOOK_RECEIVER_PID" > "$WEBHOOK_RECEIVER_PID_FILE"

    wait_for_health "http://${WEBHOOK_HOST}:${WEBHOOK_PORT}/health" "webhook receiver" 10 \
        || finalize_failure "Webhook receiver failed health check on loopback port ${WEBHOOK_PORT}"
    log "started webhook receiver for ${WEBHOOK_CHANNEL} at ${WEBHOOK_URL} (PID $WEBHOOK_RECEIVER_PID)"
}

start_metering_agent() {
    local slack_webhook=""
    local discord_webhook=""
    if [ "$WEBHOOK_CHANNEL" = "slack" ]; then
        slack_webhook="$WEBHOOK_URL"
    else
        discord_webhook="$WEBHOOK_URL"
    fi

    METERING_HEALTH_PORT="$(allocate_loopback_port)"
    METERING_NODE_ID="chaos-metering-breaker-node"
    METERING_REGION="us-east-1"
    METERING_ENVIRONMENT="${ENVIRONMENT:-local}"
    FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
    require_command cargo

    DATABASE_URL="$DATABASE_URL" \
    FLAPJACK_URL="$FAKE_METRICS_URL" \
    FLAPJACK_API_KEY="$FLAPJACK_ADMIN_KEY" \
    FLAPJACK_APPLICATION_ID="${FLAPJACK_APPLICATION_ID:-flapjack}" \
    INTERNAL_KEY="${INTERNAL_KEY:-${ADMIN_KEY:-$FLAPJACK_ADMIN_KEY}}" \
    CUSTOMER_ID="$CUSTOMER_ID" \
    NODE_ID="$METERING_NODE_ID" \
    REGION="$METERING_REGION" \
    ENVIRONMENT="$METERING_ENVIRONMENT" \
    SCRAPE_INTERVAL_SECS=1 \
    STORAGE_POLL_INTERVAL_SECS=300 \
    TENANT_MAP_REFRESH_INTERVAL_SECS=300 \
    HEALTH_PORT="$METERING_HEALTH_PORT" \
    TENANT_MAP_URL="${TENANT_MAP_URL:-http://127.0.0.1:3001/internal/tenant-map}" \
    COLD_STORAGE_USAGE_URL="${COLD_STORAGE_USAGE_URL:-http://127.0.0.1:3001/internal/cold-storage-usage}" \
    SLACK_WEBHOOK_URL="$slack_webhook" \
    DISCORD_WEBHOOK_URL="$discord_webhook" \
        nohup cargo run --manifest-path "$REPO_ROOT/infra/Cargo.toml" -p metering-agent \
            > "$METERING_AGENT_LOG_FILE" 2>&1 &
    METERING_AGENT_PID="$!"
    echo "$METERING_AGENT_PID" > "$METERING_AGENT_PID_FILE"

    wait_for_health "http://127.0.0.1:${METERING_HEALTH_PORT}/health" "metering agent health endpoint" 20 \
        || finalize_failure "Metering agent health endpoint did not become healthy at :${METERING_HEALTH_PORT}"
    log "started metering-agent (PID $METERING_AGENT_PID, health :${METERING_HEALTH_PORT})"
}

wait_for_first_successful_scrape() {
    local timeout_secs=45
    local elapsed=0
    local health_json scrape_at

    while [ "$elapsed" -lt "$timeout_secs" ]; do
        if health_json="$(curl -sf "http://127.0.0.1:${METERING_HEALTH_PORT}/health" 2>/dev/null)"; then
            scrape_at="$(printf '%s' "$health_json" | jq -r '.last_scrape_at // empty' 2>/dev/null || true)"
            if [ -n "$scrape_at" ]; then
                FIRST_SUCCESSFUL_SCRAPE_AT="$scrape_at"
                METRICS_REQUESTS_BEFORE_KILL="$(read_count_file "$FAKE_METRICS_REQUEST_COUNT_FILE")"
                log "first successful scrape observed at ${FIRST_SUCCESSFUL_SCRAPE_AT} (fake metrics requests: ${METRICS_REQUESTS_BEFORE_KILL})"
                return 0
            fi
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    finalize_failure "Timed out waiting for first successful scrape before failure injection"
}

kill_fake_metrics_by_pid_file() {
    local fake_metrics_pid
    fake_metrics_pid="$(cat "$FAKE_METRICS_PID_FILE" 2>/dev/null || true)"
    [[ "$fake_metrics_pid" =~ ^[0-9]+$ ]] \
        || finalize_failure "Fake metrics PID file is missing or invalid: $FAKE_METRICS_PID_FILE"

    if ! kill -0 "$fake_metrics_pid" 2>/dev/null; then
        finalize_failure "Fake metrics PID from pid file is not alive: $fake_metrics_pid"
    fi

    kill "$fake_metrics_pid" || finalize_failure "Failed to kill fake metrics PID ${fake_metrics_pid}"
    FORCED_FAILURE_PID="$fake_metrics_pid"
    FORCED_FAILURE_AT="$(iso_utc_now)"
    log "forced failure by killing fake metrics pid ${FORCED_FAILURE_PID} from ${FAKE_METRICS_PID_FILE}"
}

count_captured_alert_payloads() {
    local payload_files=()
    shopt -s nullglob
    payload_files=("$ARTIFACT_DIR"/webhook_payload_*.json)
    shopt -u nullglob
    printf '%s\n' "${#payload_files[@]}"
}

assert_slack_payload_metadata() {
    local payload_file="$1"

    jq -e '
        .attachments | type == "array" and length == 1 and
        .[0].color == "#d00000" and
        (.[0].fields | any(.title == "severity" and .value == "critical")) and
        (.[0].fields | any(.title == "customer_id" and (.value | length > 0))) and
        (.[0].fields | any(.title == "node_id" and (.value | length > 0))) and
        (.[0].fields | any(.title == "region" and (.value | length > 0))) and
        (.[0].fields | any(.title == "next_retry_secs" and ((.value | tostring) | test("^[0-9]+$")))) and
        (.[0].fields | any(.title == "Environment" and (.value | length > 0)))
    ' "$payload_file" >/dev/null
}

assert_discord_payload_metadata() {
    local payload_file="$1"

    jq -e '
        .embeds | type == "array" and length == 1 and
        .[0].color == 13631488 and
        (.[0].fields | any(.name == "severity" and .value == "critical")) and
        (.[0].fields | any(.name == "customer_id" and (.value | length > 0))) and
        (.[0].fields | any(.name == "node_id" and (.value | length > 0))) and
        (.[0].fields | any(.name == "region" and (.value | length > 0))) and
        (.[0].fields | any(.name == "next_retry_secs" and ((.value | tostring) | test("^[0-9]+$")))) and
        (.[0].fields | any(.name == "Environment" and (.value | length > 0)))
    ' "$payload_file" >/dev/null
}

wait_for_single_breaker_payload_and_assert_metadata() {
    local timeout_secs=90
    local elapsed=0
    local payload_count
    local payload_file

    while [ "$elapsed" -lt "$timeout_secs" ]; do
        payload_count="$(count_captured_alert_payloads)"

        if [ "$payload_count" -gt 1 ]; then
            CAPTURED_ALERT_COUNT="$payload_count"
            finalize_failure "Expected exactly one breaker-open payload but captured ${payload_count}"
        fi

        if [ "$payload_count" -eq 1 ]; then
            payload_file="$(ls -1 "$ARTIFACT_DIR"/webhook_payload_*.json 2>/dev/null | head -n 1)"
            if [ "$WEBHOOK_CHANNEL" = "slack" ]; then
                assert_slack_payload_metadata "$payload_file" \
                    || finalize_failure "Captured Slack breaker payload failed SSOT metadata assertions"
            else
                assert_discord_payload_metadata "$payload_file" \
                    || finalize_failure "Captured Discord breaker payload failed SSOT metadata assertions"
            fi

            CAPTURED_ALERT_COUNT=1
            METADATA_ASSERTIONS_PASSED=true
            log "captured exactly one breaker-open alert payload and metadata assertions passed"
            return 0
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    CAPTURED_ALERT_COUNT="$(count_captured_alert_payloads)"
    finalize_failure "Timed out waiting for breaker-open webhook payload capture"
}

if [ "$#" -ne 0 ]; then
    usage
    exit 1
fi

RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")-metering-breaker-$$"
ARTIFACT_DIR="/tmp/fjcloud-metering-breaker-proof/${RUN_ID}"
mkdir -p "$ARTIFACT_DIR"

STARTED_AT="$(iso_utc_now)"
FINISHED_AT=""
RUN_STATUS="running"
SUMMARY_REASON=""
PREPARED_LOCAL_STACK=false
LOCAL_STACK_PREFLIGHT="not_started"

WEBHOOK_CHANNEL=""
WEBHOOK_URL=""
WEBHOOK_HOST=""
WEBHOOK_PORT=""
WEBHOOK_PATH=""

FAKE_METRICS_URL=""
FAKE_METRICS_PID=""
FAKE_METRICS_PID_FILE="$ARTIFACT_DIR/fake-metrics.pid"
FAKE_METRICS_PAYLOAD_FILE="$ARTIFACT_DIR/fake-metrics.prom"
FAKE_METRICS_REQUEST_COUNT_FILE="$ARTIFACT_DIR/fake-metrics-requests.count"

WEBHOOK_RECEIVER_PID=""
WEBHOOK_RECEIVER_PID_FILE="$ARTIFACT_DIR/webhook-receiver.pid"

METERING_AGENT_PID=""
METERING_AGENT_PID_FILE="$ARTIFACT_DIR/metering-agent.pid"
METERING_AGENT_LOG_FILE="$ARTIFACT_DIR/metering-agent.log"
METERING_HEALTH_PORT=""
METERING_NODE_ID=""
METERING_REGION=""
METERING_ENVIRONMENT=""

CUSTOMER_ID=""
FIRST_SUCCESSFUL_SCRAPE_AT=""
METRICS_REQUESTS_BEFORE_KILL=0
FORCED_FAILURE_AT=""
FORCED_FAILURE_PID=""
CAPTURED_ALERT_COUNT=0
METADATA_ASSERTIONS_PASSED=false

trap cleanup EXIT

require_command jq
require_command curl
require_command python3

preflight_local_stack
start_fake_metrics_endpoint
start_webhook_receiver
start_metering_agent
wait_for_first_successful_scrape
kill_fake_metrics_by_pid_file
wait_for_single_breaker_payload_and_assert_metadata

finalize_success "metering breaker target failure proof passed"
