#!/usr/bin/env bash
# Focused tests for scripts/chaos/metering_breaker_target_failure.sh.
# Uses temp roots and mock binaries; does not touch real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/chaos/metering_breaker_target_failure.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

setup_test_root() {
    local root_dir="$1"

    mkdir -p "$root_dir/scripts/chaos" "$root_dir/scripts/lib" "$root_dir/.local" "$root_dir/bin" "$root_dir/infra"
    if [ -f "$SCRIPT_UNDER_TEST" ]; then
        cp "$SCRIPT_UNDER_TEST" "$root_dir/scripts/chaos/metering_breaker_target_failure.sh"
    fi

    cp "$REPO_ROOT/scripts/lib/env.sh" "$root_dir/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/health.sh" "$root_dir/scripts/lib/"

    cat > "$root_dir/.env.local" <<'ENV'
DATABASE_URL=postgres://test:test@localhost:5432/test
ADMIN_KEY=test-admin-key
FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000
ENVIRONMENT=local
ENV
}

run_script_in_test_root() {
    local root_dir="$1"
    shift

    local stdout_file="$root_dir/stdout.log"
    local stderr_file="$root_dir/stderr.log"

    RUN_STDOUT=""
    RUN_STDERR=""
    RUN_EXIT_CODE=0

    (
        cd "$root_dir"
        env -i \
            HOME="$root_dir" \
            PATH="$root_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            "$@" \
            bash "$root_dir/scripts/chaos/metering_breaker_target_failure.sh"
    ) >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

start_flapjack_pid_marker() {
    local root_dir="$1"
    (
        nohup sleep 300 >/dev/null 2>&1 &
        echo $! > "$root_dir/.local/flapjack.pid"
    )
}

stop_flapjack_pid_marker() {
    local root_dir="$1"
    local pid_file="$root_dir/.local/flapjack.pid"
    if [ -f "$pid_file" ]; then
        kill "$(cat "$pid_file" 2>/dev/null || true)" 2>/dev/null || true
    fi
}

write_mock_psql_customer_lookup() {
    local path="$1"
    local customer_id="$2"

    cat > "$path" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "$customer_id"
MOCK
    chmod +x "$path"
}

write_mock_cargo_agent() {
    local path="$1"
    local call_log="$2"

    cat > "$path" <<MOCK
#!/usr/bin/env bash
set -euo pipefail

echo "cargo \$*" >> "$call_log"

python3 - <<'PY'
import datetime as dt
import json
import os
import signal
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

flapjack_url = os.environ["FLAPJACK_URL"].rstrip("/")
health_port = int(os.environ["HEALTH_PORT"])
webhook_url = os.environ.get("SLACK_WEBHOOK_URL") or os.environ.get("DISCORD_WEBHOOK_URL")
environment = os.environ.get("ENVIRONMENT", "local")
customer_id = os.environ.get("CUSTOMER_ID", "")
node_id = os.environ.get("NODE_ID", "")
region = os.environ.get("REGION", "")
use_slack = bool(os.environ.get("SLACK_WEBHOOK_URL"))

state = {"last_scrape_at": None}
stop = {"value": False}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        body = {
            "status": "ok",
            "last_scrape_at": state["last_scrape_at"],
            "last_storage_poll_at": None,
        }
        encoded = json.dumps(body).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _fmt, *_args):
        return

server = ThreadingHTTPServer(("127.0.0.1", health_port), Handler)
server.timeout = 0.2

def server_loop():
    while not stop["value"]:
        server.handle_request()

thread = threading.Thread(target=server_loop, daemon=True)
thread.start()

def stop_handler(_signum, _frame):
    stop["value"] = True

signal.signal(signal.SIGTERM, stop_handler)
signal.signal(signal.SIGINT, stop_handler)

failures = 0
alert_sent = False

while not stop["value"]:
    try:
        with urllib.request.urlopen(f"{flapjack_url}/metrics", timeout=0.5) as response:
            response.read()
            if state["last_scrape_at"] is None:
                state["last_scrape_at"] = dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
            failures = 0
    except Exception:
        failures += 1
        if failures >= 5 and not alert_sent and webhook_url:
            if use_slack:
                payload = {
                    "attachments": [
                        {
                            "color": "#d00000",
                            "title": "metering-agent circuit breaker open",
                            "text": "metering scrape failures reached circuit-open state; backing off for 30 seconds",
                            "fields": [
                                {"title": "severity", "value": "critical", "short": True},
                                {"title": "customer_id", "value": customer_id, "short": True},
                                {"title": "node_id", "value": node_id, "short": True},
                                {"title": "region", "value": region, "short": True},
                                {"title": "next_retry_secs", "value": "30", "short": True},
                                {"title": "Environment", "value": environment, "short": True},
                            ],
                        }
                    ]
                }
            else:
                payload = {
                    "embeds": [
                        {
                            "color": 13631488,
                            "title": "metering-agent circuit breaker open",
                            "description": "metering scrape failures reached circuit-open state; backing off for 30 seconds",
                            "fields": [
                                {"name": "severity", "value": "critical", "inline": True},
                                {"name": "customer_id", "value": customer_id, "inline": True},
                                {"name": "node_id", "value": node_id, "inline": True},
                                {"name": "region", "value": region, "inline": True},
                                {"name": "next_retry_secs", "value": "30", "inline": True},
                                {"name": "Environment", "value": environment, "inline": True},
                            ],
                        }
                    ]
                }

            req = urllib.request.Request(
                webhook_url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=1.0) as response:
                response.read()
            alert_sent = True

    time.sleep(0.2)

stop["value"] = True
thread.join(timeout=1.0)
server.server_close()
PY
MOCK
    chmod +x "$path"
}

extract_artifacts_dir() {
    local output="$1"
    printf '%s\n' "$output" | sed -n 's/.*Artifacts: //p' | tail -n 1
}

test_metering_breaker_script_exists() {
    if [ -x "$SCRIPT_UNDER_TEST" ]; then
        pass "metering breaker chaos script should exist and be executable"
    else
        fail "metering breaker chaos script should exist and be executable"
    fi
}

test_preflight_fails_closed_when_local_stack_not_prepared() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_test_root "$tmp_dir"

    run_script_in_test_root "$tmp_dir" "SLACK_WEBHOOK_URL=http://127.0.0.1:19091/slack"

    local combined_output
    combined_output="${RUN_STDOUT}"$'\n'"${RUN_STDERR}"
    assert_eq "$RUN_EXIT_CODE" "1" \
        "script should fail closed when prepared local stack prerequisites are missing"
    assert_contains "$combined_output" "scripts/local-dev-up.sh" \
        "preflight failure should direct operators to local-dev-up owner"
    assert_contains "$combined_output" "scripts/seed_local.sh" \
        "preflight failure should direct operators to seed_local owner"
}

test_preflight_rejects_non_loopback_webhook_before_starting_agent() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'stop_flapjack_pid_marker "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"' RETURN

    setup_test_root "$tmp_dir"
    start_flapjack_pid_marker "$tmp_dir"

    write_mock_psql_customer_lookup "$tmp_dir/bin/psql" "550e8400-e29b-41d4-a716-446655440000"
    write_mock_script "$tmp_dir/bin/cargo" 'echo "unexpected cargo run" >> "'"$tmp_dir"'/cargo.log"; exit 0'

    run_script_in_test_root "$tmp_dir" "SLACK_WEBHOOK_URL=https://hooks.slack.com/services/not-local"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "script should reject non-loopback webhook URL"
    assert_contains "$RUN_STDERR" "loopback" \
        "non-loopback rejection should explain local-only webhook contract"

    local cargo_log
    cargo_log="$(cat "$tmp_dir/cargo.log" 2>/dev/null || true)"
    assert_eq "$cargo_log" "" \
        "script should reject non-loopback webhook URL before invoking metering agent"
}

test_preflight_rejects_multi_channel_configuration() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'stop_flapjack_pid_marker "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"' RETURN

    setup_test_root "$tmp_dir"
    start_flapjack_pid_marker "$tmp_dir"
    write_mock_psql_customer_lookup "$tmp_dir/bin/psql" "550e8400-e29b-41d4-a716-446655440000"

    run_script_in_test_root "$tmp_dir" \
        "SLACK_WEBHOOK_URL=http://127.0.0.1:19091/slack" \
        "DISCORD_WEBHOOK_URL=http://127.0.0.1:19092/discord"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "script should fail when both Slack and Discord channels are configured"
    assert_contains "$RUN_STDERR" "exactly one" \
        "multi-channel rejection should explain single-channel proof contract"
}

test_script_enforces_pid_file_kill_contract() {
    if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
        fail "pid-file kill contract test requires script to exist"
        return
    fi

    local script_text
    script_text="$(cat "$SCRIPT_UNDER_TEST")"

    assert_contains "$script_text" "FAKE_METRICS_PID_FILE" \
        "script should track fake metrics PID via dedicated pid file"
    assert_contains "$script_text" 'kill "$fake_metrics_pid"' \
        "forced failure should kill only the fake-metrics pid captured from file"
    assert_not_contains "$script_text" "pkill -f" \
        "forced failure should not use broad process pattern kills"
    assert_not_contains "$script_text" "killall" \
        "forced failure should not use global killall"
}

test_happy_path_records_single_alert_and_required_metadata() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'stop_flapjack_pid_marker "'"$tmp_dir"'"; rm -rf "'"$tmp_dir"'"' RETURN

    setup_test_root "$tmp_dir"
    start_flapjack_pid_marker "$tmp_dir"

    local customer_id="550e8400-e29b-41d4-a716-446655440000"
    local call_log="$tmp_dir/cargo_calls.log"
    write_mock_psql_customer_lookup "$tmp_dir/bin/psql" "$customer_id"
    write_mock_cargo_agent "$tmp_dir/bin/cargo" "$call_log"

    run_script_in_test_root "$tmp_dir" \
        "SLACK_WEBHOOK_URL=http://127.0.0.1:19091/slack"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "happy path should complete successfully"
    assert_contains "$RUN_STDOUT" "first successful scrape observed" \
        "run should record proof of first successful scrape before failure"
    assert_contains "$RUN_STDOUT" "forced failure by killing fake metrics pid" \
        "run should log explicit forced-failure kill evidence"
    assert_contains "$RUN_STDOUT" "captured exactly one breaker-open alert payload" \
        "run should report exactly one captured breaker-open payload"

    local artifacts_dir
    artifacts_dir="$(extract_artifacts_dir "$RUN_STDOUT")"
    if [ -n "$artifacts_dir" ] && [ -d "$artifacts_dir" ]; then
        pass "run should emit a valid artifacts directory"
    else
        fail "run should emit a valid artifacts directory"
        return
    fi

    local summary_json
    summary_json="$artifacts_dir/summary.json"
    if [ -f "$summary_json" ]; then
        pass "summary.json should be written"
    else
        fail "summary.json should be written"
        return
    fi

    if python3 - "$summary_json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding='utf-8'))
if summary.get("status") != "passed":
    raise SystemExit(1)
forced = summary.get("forced_failure", {})
fake = summary.get("fake_metrics", {})
if not forced.get("killed_pid"):
    raise SystemExit(1)
if str(forced.get("killed_pid")) != str(fake.get("pid")):
    raise SystemExit(1)
if summary.get("captured_alert_count") != 1:
    raise SystemExit(1)
if not summary.get("first_successful_scrape_at"):
    raise SystemExit(1)
PY
    then
        pass "summary should capture first scrape, exact kill pid evidence, and single alert count"
    else
        fail "summary should capture first scrape, exact kill pid evidence, and single alert count"
    fi

    local payload_count
    payload_count="$(ls -1 "$artifacts_dir"/webhook_payload_*.json 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$payload_count" "1" \
        "run should persist exactly one captured webhook payload file"

    local payload_file
    payload_file="$(ls -1 "$artifacts_dir"/webhook_payload_*.json 2>/dev/null | head -n 1)"

    if jq -e '
        .attachments | type == "array" and length == 1 and
        .[0].color == "#d00000" and
        (.[0].fields | any(.title == "severity" and .value == "critical")) and
        (.[0].fields | any(.title == "customer_id" and (.value | length > 0))) and
        (.[0].fields | any(.title == "node_id" and (.value | length > 0))) and
        (.[0].fields | any(.title == "region" and (.value | length > 0))) and
        (.[0].fields | any(.title == "next_retry_secs" and ((.value | tostring) | test("^[0-9]+$")))) and
        (.[0].fields | any(.title == "Environment" and (.value | length > 0)))
    ' "$payload_file" >/dev/null 2>&1; then
        pass "captured payload should contain required SSOT metadata and critical severity encoding"
    else
        fail "captured payload should contain required SSOT metadata and critical severity encoding"
    fi

    local cargo_calls
    cargo_calls="$(cat "$call_log" 2>/dev/null || true)"
    assert_contains "$cargo_calls" "-p metering-agent" \
        "script should invoke metering-agent crate during chaos proof"
}

main() {
    echo "=== chaos metering breaker proof tests ==="
    echo ""

    test_metering_breaker_script_exists
    test_preflight_fails_closed_when_local_stack_not_prepared
    test_preflight_rejects_non_loopback_webhook_before_starting_agent
    test_preflight_rejects_multi_channel_configuration
    test_script_enforces_pid_file_kill_contract
    test_happy_path_records_single_alert_and_required_metadata

    run_test_summary
}

main "$@"
