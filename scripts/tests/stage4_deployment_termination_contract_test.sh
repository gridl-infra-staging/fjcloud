#!/usr/bin/env bash
# Stage 4 admin-deployment-termination runner contract.
#
# Drives the Stage 4 runner at
#   docs/runbooks/evidence/prod_db_leak_cleanup/20260521T191408Z_stage4_deployment_termination/00_commands.sh
# against a Python HTTP capture server that emulates the prod/staging
# admin API surface and against fixture exact-cohort CSVs that mirror the
# Stage 1 shape, then asserts:
#
#   - GET /admin/tenants/{id}/deployments?include_terminated=true is issued
#     for every customer BEFORE any DELETE for that customer.
#   - Pre-terminated deployments are NOT mutated; their disposition entry
#     records execution_disposition=already_terminated_noop.
#   - Customer IDs absent from the fixture exact-cohort CSV are NEVER hit
#     (no GET, no DELETE) — the runner uses the Stage 1 CSVs as the sole
#     source of truth for which customers it may touch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE4_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T191408Z_stage4_deployment_termination"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR="$(mktemp -d -t stage4_contract_XXXXXX)"
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
# Mock admin-API server.
#
# Per-customer GET response is read from $WORK_DIR/server_state/<customer_id>.json.
# DELETE response for a deployment id always 204 unless the deployment id is
# in the "pre_terminated" set (already terminated in fixture) — in which case
# the runner should never call DELETE for it. The mock instead logs the call
# as a contract violation; the assertion below checks the request log.
# ---------------------------------------------------------------------------
SERVER_PORT_FILE="$WORK_DIR/port"
REQUEST_LOG="$WORK_DIR/requests.log"
SERVER_STATE_DIR="$WORK_DIR/server_state"
mkdir -p "$SERVER_STATE_DIR"

SERVER_SCRIPT="$WORK_DIR/mock_admin_server.py"
cat > "$SERVER_SCRIPT" <<'PYEOF'
import http.server
import json
import re
import sys
from pathlib import Path

port_file = Path(sys.argv[1])
log_path = Path(sys.argv[2])
state_dir = Path(sys.argv[3])

LIST_RE = re.compile(r"^/admin/tenants/([0-9a-fA-F-]+)/deployments")
DELETE_RE = re.compile(r"^/admin/deployments/([0-9a-fA-F-]+)$")


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _log(self, method, path):
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(f"{method}\t{path}\n")

    def do_GET(self):
        self._log("GET", self.path)
        m = LIST_RE.match(self.path)
        if not m:
            self.send_response(404)
            self.end_headers()
            return
        customer_id = m.group(1)
        state_file = state_dir / f"{customer_id}.json"
        if not state_file.exists():
            # Stage 4 must only ever query customers from the fixture CSV.
            # Returning 404 here is louder than 200-empty so a fault is visible.
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"unknown customer (contract violation)"}')
            return
        body = state_file.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        self._log("DELETE", self.path)
        m = DELETE_RE.match(self.path)
        if not m:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(204)
        self.end_headers()


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port = server.server_port
port_file.write_text(str(port), encoding="utf-8")
server.serve_forever()
PYEOF

python3 "$SERVER_SCRIPT" "$SERVER_PORT_FILE" "$REQUEST_LOG" "$SERVER_STATE_DIR" &
SERVER_PID=$!

# Wait for the server to bind.
for _ in $(seq 1 50); do
    if [ -s "$SERVER_PORT_FILE" ]; then
        break
    fi
    sleep 0.05
done
if [ ! -s "$SERVER_PORT_FILE" ]; then
    fail "mock server failed to bind a port"
    run_test_summary
    exit 1
fi
PORT="$(cat "$SERVER_PORT_FILE")"
MOCK_BASE="http://127.0.0.1:${PORT}"

# ---------------------------------------------------------------------------
# Fixture CSVs + server state.
#
# Prod fixture covers four cases:
#   - aaaaaaaa: deployment running (must be DELETEd)
#   - bbbbbbbb: deployment already terminated (must NOT be DELETEd)
#   - cccccccc: zero deployments (no DELETE)
#   - dddddddd: two deployments, one running and one terminated; only the
#     running id must be DELETEd
# Staging fixture covers one running customer.
# An additional rogue customer e0e0... is NOT in either CSV; the contract
# asserts the runner never queries or mutates it.
# ---------------------------------------------------------------------------
FIXTURE_DIR="$WORK_DIR/fixture_stage1"
mkdir -p "$FIXTURE_DIR"

PROD_RUN_CUSTOMER="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PROD_TERM_CUSTOMER="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
PROD_EMPTY_CUSTOMER="cccccccc-cccc-cccc-cccc-cccccccccccc"
PROD_MIXED_CUSTOMER="dddddddd-dddd-dddd-dddd-dddddddddddd"
STAGING_CUSTOMER="11111111-2222-3333-4444-555555555555"
ROGUE_CUSTOMER="e0e0e0e0-e0e0-e0e0-e0e0-e0e0e0e0e0e0"

cat > "$FIXTURE_DIR/10_prod_exact_cleanup.csv" <<CSV
customer_id,email,status,deleted_at,stripe_customer_id,tenant_id,deployment_id,deployment_status,provider_vm_id,hostname,flapjack_url,ip_address,created_at
$PROD_RUN_CUSTOMER,a@e2e.griddle.test,active,,,,,,,,,,2026-05-18 03:02:34+00
$PROD_TERM_CUSTOMER,b@e2e.griddle.test,active,,,,,,,,,,2026-05-18 03:02:35+00
$PROD_EMPTY_CUSTOMER,c@e2e.griddle.test,active,,,,,,,,,,2026-05-18 03:02:36+00
$PROD_MIXED_CUSTOMER,d@e2e.griddle.test,active,,,,,,,,,,2026-05-18 03:02:37+00
CSV

cat > "$FIXTURE_DIR/11_staging_exact_cleanup.csv" <<CSV
customer_id,email,status,deleted_at,stripe_customer_id,tenant_id,deployment_id,deployment_status,provider_vm_id,hostname,flapjack_url,ip_address,created_at
$STAGING_CUSTOMER,s@e2e.griddle.test,active,,,,,,,,,,2026-05-19 05:58:48+00
CSV

# Per-customer GET responses.
RUN_DEPLOY_ID="11111111-aaaa-bbbb-cccc-111111111111"
TERM_DEPLOY_ID="22222222-aaaa-bbbb-cccc-222222222222"
MIXED_RUN_DEPLOY_ID="33333333-aaaa-bbbb-cccc-333333333333"
MIXED_TERM_DEPLOY_ID="44444444-aaaa-bbbb-cccc-444444444444"
STAGING_DEPLOY_ID="55555555-aaaa-bbbb-cccc-555555555555"

emit_deployment_state() {
    local customer_id="$1" out="$2"
    shift 2
    python3 - "$customer_id" "$out" "$@" <<'PY'
import json
import sys

customer_id = sys.argv[1]
out_path = sys.argv[2]
rows = []
i = 3
while i < len(sys.argv):
    deploy_id = sys.argv[i]
    status = sys.argv[i + 1]
    rows.append({
        "id": deploy_id,
        "customer_id": customer_id,
        "node_id": f"node-{deploy_id[:8]}",
        "region": "us-east-1",
        "vm_type": "small",
        "vm_provider": "aws",
        "ip_address": "203.0.113.1" if status != "terminated" else None,
        "status": status,
        "created_at": "2026-05-18T03:00:00Z",
        "terminated_at": "2026-05-18T04:00:00Z" if status == "terminated" else None,
        "provider_vm_id": f"i-{deploy_id[:12]}",
        "hostname": f"{deploy_id[:8]}.cloud.flapjack.foo",
        "flapjack_url": f"https://{deploy_id[:8]}.cloud.flapjack.foo",
        "health_status": "unknown",
        "last_health_check_at": None,
    })
    i += 2
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(rows, fh)
PY
}

emit_deployment_state "$PROD_RUN_CUSTOMER"   "$SERVER_STATE_DIR/$PROD_RUN_CUSTOMER.json"   "$RUN_DEPLOY_ID" "running"
emit_deployment_state "$PROD_TERM_CUSTOMER"  "$SERVER_STATE_DIR/$PROD_TERM_CUSTOMER.json"  "$TERM_DEPLOY_ID" "terminated"
emit_deployment_state "$PROD_EMPTY_CUSTOMER" "$SERVER_STATE_DIR/$PROD_EMPTY_CUSTOMER.json"
emit_deployment_state "$PROD_MIXED_CUSTOMER" "$SERVER_STATE_DIR/$PROD_MIXED_CUSTOMER.json" \
    "$MIXED_RUN_DEPLOY_ID" "running" "$MIXED_TERM_DEPLOY_ID" "terminated"
emit_deployment_state "$STAGING_CUSTOMER"    "$SERVER_STATE_DIR/$STAGING_CUSTOMER.json"    "$STAGING_DEPLOY_ID" "running"

# Important: do NOT populate state for $ROGUE_CUSTOMER. Any query for it
# would return 404 and the request log would record it as a violation.

# ---------------------------------------------------------------------------
# Run the runner under contract overrides.
# ---------------------------------------------------------------------------
RUN_OUT_DIR="$WORK_DIR/stage4_run"
mkdir -p "$RUN_OUT_DIR"

RUNNER="$STAGE4_DIR/00_commands.sh"
assert_file_exists "$RUNNER" "stage 4 runner exists"

set +e
STAGE4_TEST_MODE=1 \
STAGE4_OUT_DIR="$RUN_OUT_DIR" \
STAGE4_STAGE1_DIR="$FIXTURE_DIR" \
STAGE4_API_URL_PROD="$MOCK_BASE" \
STAGE4_API_URL_STAGING="$MOCK_BASE" \
STAGE4_ADMIN_KEY_PROD="test-prod-admin-key" \
STAGE4_ADMIN_KEY_STAGING="test-staging-admin-key" \
    bash "$RUNNER" primary > "$WORK_DIR/runner_stdout.txt" 2> "$WORK_DIR/runner_stderr.txt"
RUNNER_RC=$?
set -e

if [ "$RUNNER_RC" -ne 0 ]; then
    echo "--- runner stdout ---" >&2
    cat "$WORK_DIR/runner_stdout.txt" >&2 || true
    echo "--- runner stderr ---" >&2
    cat "$WORK_DIR/runner_stderr.txt" >&2 || true
    fail "stage4 runner exited non-zero ($RUNNER_RC)"
    run_test_summary
    exit 1
fi

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------
REQ_LOG_CONTENT="$(cat "$REQUEST_LOG" 2>/dev/null || true)"

# 1. Rogue customer is never hit.
assert_not_contains "$REQ_LOG_CONTENT" "/admin/tenants/$ROGUE_CUSTOMER/" \
    "rogue customer ID never appears in request log"

# 2. GET appears before DELETE for the running customer.
RUN_CUSTOMER_GET_LINE="$(grep -n "GET	/admin/tenants/$PROD_RUN_CUSTOMER/deployments" "$REQUEST_LOG" | head -n1 | cut -d: -f1 || true)"
RUN_DEPLOY_DELETE_LINE="$(grep -n "DELETE	/admin/deployments/$RUN_DEPLOY_ID" "$REQUEST_LOG" | head -n1 | cut -d: -f1 || true)"
if [ -z "$RUN_CUSTOMER_GET_LINE" ] || [ -z "$RUN_DEPLOY_DELETE_LINE" ]; then
    fail "runner did not issue both a list and a delete for the running customer (GET line='$RUN_CUSTOMER_GET_LINE' DELETE line='$RUN_DEPLOY_DELETE_LINE')"
elif [ "$RUN_CUSTOMER_GET_LINE" -ge "$RUN_DEPLOY_DELETE_LINE" ]; then
    fail "list must occur strictly before delete for $PROD_RUN_CUSTOMER (GET=$RUN_CUSTOMER_GET_LINE DELETE=$RUN_DEPLOY_DELETE_LINE)"
else
    pass "list precedes delete for prod running customer"
fi

# 3. Pre-terminated deployment is never DELETEd.
assert_not_contains "$REQ_LOG_CONTENT" "DELETE	/admin/deployments/$TERM_DEPLOY_ID" \
    "pre-terminated deployment never receives DELETE"
assert_not_contains "$REQ_LOG_CONTENT" "DELETE	/admin/deployments/$MIXED_TERM_DEPLOY_ID" \
    "pre-terminated mixed-customer deployment never receives DELETE"

# 4. The running deployment of the mixed customer IS deleted.
assert_contains "$REQ_LOG_CONTENT" "DELETE	/admin/deployments/$MIXED_RUN_DEPLOY_ID" \
    "running deployment of mixed customer receives DELETE"

# 5. Disposition table records the right outcomes.
DISP_FILE=""
for candidate in "$RUN_OUT_DIR/runs/primary/31_termination_dispositions.csv" \
                 "$RUN_OUT_DIR/runs/primary/30_termination_dispositions.json" \
                 "$RUN_OUT_DIR/runs/primary/31_termination_dispositions.json" \
                 "$RUN_OUT_DIR/runs/primary/30_termination_dispositions.csv"; do
    if [ -f "$candidate" ]; then
        DISP_FILE="$candidate"
        break
    fi
done
if [ -z "$DISP_FILE" ]; then
    fail "no termination dispositions file produced under $RUN_OUT_DIR/runs/primary"
else
    pass "disposition table produced at $DISP_FILE"
    DISP_CONTENT="$(cat "$DISP_FILE")"
    assert_contains "$DISP_CONTENT" "already_terminated_noop" \
        "disposition table records already_terminated_noop"
    assert_contains "$DISP_CONTENT" "terminated_via_admin_route" \
        "disposition table records terminated_via_admin_route"
    assert_contains "$DISP_CONTENT" "no_deployments" \
        "disposition table records no_deployments for empty customer"
fi

run_test_summary
