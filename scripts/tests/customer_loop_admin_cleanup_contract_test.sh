#!/usr/bin/env bash
# Hermetic regression test: run_admin_cleanup_step in the customer-loop canary
# must emit DELETE /admin/tenants/<uuid> with x-admin-key set byte-for-byte to
# the configured ADMIN_KEY. The test drives the real admin_call code path
# (sourced via scripts/canary/customer_loop_synthetic.sh, which transitively
# sources scripts/lib/http_json.sh) against a single-request Python HTTP
# capture server bound to 127.0.0.1:0 — no AWS creds, no network egress, no
# reads from /etc/fjcloud/env or .env.secret.
#
# Why this test is shaped this way:
#   - The Stage 1 evidence bundle showed admin_cleanup 401s in prod with no
#     repro in the inline session. If a future refactor renames the
#     x-admin-key header or drops it, prod canary will silently 401 the same
#     way. This test fails-red on either drift class.
#   - It deliberately does NOT call load_canary_env — that function would
#     attempt SSM/network work; the test owns env wiring directly.
#   - It stubs dispatch_failure_alert so a failed assertion path can never
#     reach Slack/Discord.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANARY_SCRIPT="$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$CANARY_SCRIPT" ]; then
    fail "canary script exists at scripts/canary/customer_loop_synthetic.sh"
    run_test_summary
    exit 1
fi

# Pre-export an ALERT_DISPATCH_HELPER value so sourcing the canary owner does
# not exit on validate_alert_dispatch_helper. The canonical helper lives in
# scripts/lib/ which is the only allowed directory.
export ALERT_DISPATCH_HELPER="$REPO_ROOT/scripts/lib/alert_dispatch.sh"

# shellcheck source=scripts/canary/customer_loop_synthetic.sh
source "$CANARY_SCRIPT"

# Override dispatch_failure_alert so the test can never page real webhooks
# even if an assertion failure drives mark_failure -> dispatch path.
dispatch_failure_alert() {
    echo "[test-stub] dispatch_failure_alert called: $*" >&2
    return 0
}

WORK_DIR="$(mktemp -d -t admin_cleanup_contract_XXXXXX)"
SERVER_PID=""

cleanup() {
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Single-request HTTP capture server.
#
# Pattern matches stage4_deployment_termination_contract_test.sh /
# stage5_tenant_soft_delete_contract_test.sh — Python http.server bound to
# 127.0.0.1:0 with the chosen port written back through a file. The handler
# writes one record per request: the request line on the first line, then one
# "Header-Name: value" line per header, then a blank line terminator. Always
# responds 204 No Content.
# ---------------------------------------------------------------------------
SERVER_PORT_FILE="$WORK_DIR/port"
REQUEST_LOG="$WORK_DIR/requests.log"
SERVER_SCRIPT="$WORK_DIR/capture_server.py"

cat > "$SERVER_SCRIPT" <<'PYEOF'
import http.server
import sys
from pathlib import Path

port_file = Path(sys.argv[1])
log_path = Path(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _record(self):
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(f"{self.command} {self.path}\n")
            for name, value in self.headers.items():
                fh.write(f"{name}: {value}\n")
            fh.write("\n")

    def do_DELETE(self):
        self._record()
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._record()
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PYEOF

python3 "$SERVER_SCRIPT" "$SERVER_PORT_FILE" "$REQUEST_LOG" &
SERVER_PID=$!

# Wait for the server to bind.
for _ in $(seq 1 50); do
    if [ -s "$SERVER_PORT_FILE" ]; then
        break
    fi
    sleep 0.05
done
if [ ! -s "$SERVER_PORT_FILE" ]; then
    fail "capture server failed to bind a port"
    run_test_summary
    exit 1
fi
PORT="$(cat "$SERVER_PORT_FILE")"

# ---------------------------------------------------------------------------
# Test env wiring.
#
# These mirror what load_canary_env would set, EXCEPT we set them ourselves so
# the test stays hermetic (no SSM, no .env.secret read, no /etc/fjcloud/env).
# ---------------------------------------------------------------------------
TEST_ADMIN_KEY="/uiaeMnmRzsOPw0aEglARrv5hW6GX0pi"  # leading "/" exercises the same
                                                   # value class that previously
                                                   # tripped the SSM re-resolve bug.
TEST_CUSTOMER_ID="11111111-2222-3333-4444-555555555555"

export API_URL="http://127.0.0.1:${PORT}"
export ADMIN_KEY="$TEST_ADMIN_KEY"
export CANARY_CUSTOMER_ID="$TEST_CUSTOMER_ID"
CANARY_ADMIN_CLEANED=0

# Reset HTTP response globals so a stale value cannot mask a real failure.
HTTP_RESPONSE_CODE=""
HTTP_RESPONSE_BODY=""
HTTP_RESPONSE_EXIT_STATUS=""
FLOW_FAILED=0
FLOW_FAILURE_STEP=""
FLOW_FAILURE_DETAIL=""

# ---------------------------------------------------------------------------
# Drive the real seam.
# ---------------------------------------------------------------------------
set +e
run_admin_cleanup_step
RUN_RC=$?
set -e

assert_eq "$RUN_RC" "0" \
    "run_admin_cleanup_step should exit 0 against a 204-responding admin API"
assert_eq "$HTTP_RESPONSE_CODE" "204" \
    "admin_call should observe HTTP 204 from the capture server"
assert_eq "$FLOW_FAILED" "0" \
    "run_admin_cleanup_step should not set FLOW_FAILED on success"
assert_eq "$CANARY_ADMIN_CLEANED" "1" \
    "run_admin_cleanup_step should set CANARY_ADMIN_CLEANED=1 on success"

# ---------------------------------------------------------------------------
# Parse the captured request log and assert request-shape contract.
# ---------------------------------------------------------------------------
if [ ! -s "$REQUEST_LOG" ]; then
    fail "capture server should have recorded at least one request"
    run_test_summary
    exit 1
fi

REQUEST_LINE="$(awk 'NR==1{print; exit}' "$REQUEST_LOG")"
EXPECTED_REQUEST_LINE="DELETE /admin/tenants/${TEST_CUSTOMER_ID}"
assert_eq "$REQUEST_LINE" "$EXPECTED_REQUEST_LINE" \
    "request line should be exactly DELETE /admin/tenants/<uuid>"

# Header parsing: case-insensitive header name match, value asserted
# byte-for-byte (no leading/trailing whitespace tolerated beyond the single
# ": " separator emitted by Python http.server).
CAPTURED_HEADER_VALUE="$(
    awk 'BEGIN{IGNORECASE=1} NR>1 && /^[Xx]-[Aa]dmin-[Kk]ey:[[:space:]]/ {
        sub(/^[^:]+:[[:space:]]/, "")
        print
        exit
    }' "$REQUEST_LOG"
)"

if [ -z "$CAPTURED_HEADER_VALUE" ]; then
    fail "capture server should have received an x-admin-key header on the DELETE request (log: $(cat "$REQUEST_LOG"))"
else
    pass "capture server received an x-admin-key header on the DELETE request"
fi

# CRITICAL: assert the captured value matches the configured ADMIN_KEY
# byte-for-byte. This is the regression contract — header value drift (e.g.
# silent trim, partial substitution, hardcoded fallback) must fail-red.
assert_eq "$CAPTURED_HEADER_VALUE" "$TEST_ADMIN_KEY" \
    "x-admin-key header value should equal the configured ADMIN_KEY byte-for-byte"

# Belt-and-suspenders: assert no second x-admin-key header was emitted (which
# could mask a drift if assertions only checked the first).
DUPLICATE_HEADER_COUNT="$(
    awk 'BEGIN{IGNORECASE=1; c=0} /^[Xx]-[Aa]dmin-[Kk]ey:/ {c++} END{print c}' "$REQUEST_LOG"
)"
assert_eq "$DUPLICATE_HEADER_COUNT" "1" \
    "exactly one x-admin-key header should be emitted on the DELETE request"

# Also assert exactly one request was captured (the function should not retry
# on a successful 204).
REQUEST_COUNT="$(awk 'NR==1 || (prev=="" && $0!="") {c++} {prev=$0} END{print c+0}' "$REQUEST_LOG")"
assert_eq "$REQUEST_COUNT" "1" \
    "run_admin_cleanup_step should issue exactly one HTTP request on success"

run_test_summary
