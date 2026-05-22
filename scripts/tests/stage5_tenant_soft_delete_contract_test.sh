#!/usr/bin/env bash
# Stage 5 tenant soft-delete runner contract.
#
# Drives the Stage 5 runner at
#   docs/runbooks/evidence/prod_db_leak_cleanup/20260521T193529Z_stage5_tenant_soft_delete/00_commands.sh
# against a mock admin API plus a mock staging_db helper, then asserts:
#
#   - Only same-environment customer IDs from Stage 1 exact CSVs are processed.
#   - Only Stage 4 `customer_disposition == no_deployments` rows trigger
#     DELETE /admin/tenants/{id}.
#   - Staging `list_http_404` rows remain verification-only and require a
#     read-only DB proof with status='deleted' and deleted_at IS NOT NULL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGE5_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T193529Z_stage5_tenant_soft_delete"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR="$(mktemp -d -t stage5_contract_XXXXXX)"
SERVER_PID=""

cleanup() {
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

SERVER_PORT_FILE="$WORK_DIR/port"
REQUEST_LOG="$WORK_DIR/requests.log"
SERVER_SCRIPT="$WORK_DIR/mock_admin_server.py"

cat > "$SERVER_SCRIPT" <<'PYEOF'
import http.server
import re
import sys
from pathlib import Path

port_file = Path(sys.argv[1])
request_log = Path(sys.argv[2])

DELETE_RE = re.compile(r"^/admin/tenants/([0-9a-fA-F-]+)$")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _log(self, method, path):
        with request_log.open("a", encoding="utf-8") as fh:
            fh.write(f"{method}\t{path}\n")

    def do_DELETE(self):
        self._log("DELETE", self.path)
        m = DELETE_RE.match(self.path)
        if not m:
            self.send_response(404)
            self.end_headers()
            return
        customer_id = m.group(1)
        if customer_id.startswith("cccc"):
            # Simulate already-deleted response.
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"tenant not found"}')
            return
        self.send_response(204)
        self.end_headers()

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PYEOF

python3 "$SERVER_SCRIPT" "$SERVER_PORT_FILE" "$REQUEST_LOG" &
SERVER_PID=$!

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

FIXTURE_STAGE1="$WORK_DIR/stage1"
mkdir -p "$FIXTURE_STAGE1"

PROD_DELETE_CUSTOMER="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
STAGING_VERIFY_CUSTOMER="cccccccc-cccc-cccc-cccc-cccccccccccc"
STAGING_DELETE_CUSTOMER="dddddddd-dddd-dddd-dddd-dddddddddddd"
ROGUE_CUSTOMER="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

cat > "$FIXTURE_STAGE1/10_prod_exact_cleanup.csv" <<CSV
customer_id,email,status,deleted_at,stripe_customer_id,tenant_id,deployment_id,deployment_status,provider_vm_id,hostname,flapjack_url,ip_address,created_at
$PROD_DELETE_CUSTOMER,prod-delete@e2e.griddle.test,active,,,,,,,,,,2026-05-18 03:02:34+00
CSV

cat > "$FIXTURE_STAGE1/11_staging_exact_cleanup.csv" <<CSV
customer_id,email,status,deleted_at,stripe_customer_id,tenant_id,deployment_id,deployment_status,provider_vm_id,hostname,flapjack_url,ip_address,created_at
$STAGING_VERIFY_CUSTOMER,staging-verify@e2e.griddle.test,deleted,2026-05-18 03:41:13+00,,,,,,,,,2026-05-18 03:40:39+00
$STAGING_DELETE_CUSTOMER,staging-delete@e2e.griddle.test,active,,,,,,,,,,2026-05-19 05:58:48+00
CSV

FIXTURE_STAGE4="$WORK_DIR/stage4"
mkdir -p "$FIXTURE_STAGE4"

cat > "$FIXTURE_STAGE4/40_stage4_summary.json" <<JSON
{
  "stage": "stage4_deployment_termination",
  "customer_dispositions": {
    "prod": {
      "$PROD_DELETE_CUSTOMER": {
        "customer_disposition": "no_deployments",
        "deployment_rows": [
          {
            "execution_reason": "customer_has_zero_deployments",
            "list_http_code": "200"
          }
        ]
      }
    },
    "staging": {
      "$STAGING_VERIFY_CUSTOMER": {
        "customer_disposition": "list_failed",
        "deployment_rows": [
          {
            "execution_reason": "list_http_404",
            "list_http_code": "404"
          }
        ]
      },
      "$STAGING_DELETE_CUSTOMER": {
        "customer_disposition": "no_deployments",
        "deployment_rows": [
          {
            "execution_reason": "customer_has_zero_deployments",
            "list_http_code": "200"
          }
        ]
      }
    }
  }
}
JSON

MOCK_STAGING_DB="$WORK_DIR/mock_staging_db.sh"
cat > "$MOCK_STAGING_DB" <<'EOF_DB'
#!/usr/bin/env bash
staging_db_run_sql() {
    local _database_url="$1"
    local sql="$2"
    local out_path="${STAGE5_MOCK_STAGING_DB_LOG:?STAGE5_MOCK_STAGING_DB_LOG missing}"
    printf '%s\n' "$sql" >> "$out_path"
    local customer_id
    customer_id="$(printf '%s' "$sql" | sed -n "s/.*id = '\([0-9a-fA-F-]*\)'.*/\1/p")"
    if [ -z "$customer_id" ]; then
        echo "status,deleted_at"
        echo ","
        return 0
    fi
    if [ "$customer_id" = "cccccccc-cccc-cccc-cccc-cccccccccccc" ]; then
        echo "status,deleted_at"
        echo "deleted,2026-05-18T03:41:13Z"
        return 0
    fi
    echo "status,deleted_at"
    echo "active,"
}
EOF_DB
chmod +x "$MOCK_STAGING_DB"

RUN_OUT_DIR="$WORK_DIR/stage5_run"
RUNNER="$STAGE5_DIR/00_commands.sh"
assert_file_exists "$RUNNER" "stage 5 runner exists"

set +e
STAGE5_TEST_MODE=1 \
STAGE5_OUT_DIR="$RUN_OUT_DIR" \
STAGE5_STAGE1_DIR="$FIXTURE_STAGE1" \
STAGE5_STAGE4_SUMMARY_JSON="$FIXTURE_STAGE4/40_stage4_summary.json" \
STAGE5_API_URL_PROD="$MOCK_BASE" \
STAGE5_API_URL_STAGING="$MOCK_BASE" \
STAGE5_ADMIN_KEY_PROD="test-prod-admin-key" \
STAGE5_ADMIN_KEY_STAGING="test-staging-admin-key" \
STAGE5_STAGING_DB_HELPER="$MOCK_STAGING_DB" \
STAGE5_MOCK_STAGING_DB_LOG="$WORK_DIR/staging_db_queries.log" \
STAGE5_STAGING_DATABASE_URL="postgres://mock/staging" \
    bash "$RUNNER" primary > "$WORK_DIR/runner_stdout.txt" 2> "$WORK_DIR/runner_stderr.txt"
RUNNER_RC=$?
set -e

if [ "$RUNNER_RC" -ne 0 ]; then
    echo "--- runner stdout ---" >&2
    cat "$WORK_DIR/runner_stdout.txt" >&2 || true
    echo "--- runner stderr ---" >&2
    cat "$WORK_DIR/runner_stderr.txt" >&2 || true
    fail "stage5 runner exited non-zero ($RUNNER_RC)"
    run_test_summary
    exit 1
fi

REQ_LOG_CONTENT="$(cat "$REQUEST_LOG" 2>/dev/null || true)"

assert_contains "$REQ_LOG_CONTENT" $'DELETE\t/admin/tenants/'"$PROD_DELETE_CUSTOMER" \
    "prod no_deployments customer receives DELETE"
assert_contains "$REQ_LOG_CONTENT" $'DELETE\t/admin/tenants/'"$STAGING_DELETE_CUSTOMER" \
    "staging no_deployments customer receives DELETE"
assert_not_contains "$REQ_LOG_CONTENT" $'DELETE\t/admin/tenants/'"$STAGING_VERIFY_CUSTOMER" \
    "staging list_http_404 customer is verification-only"
assert_not_contains "$REQ_LOG_CONTENT" $'DELETE\t/admin/tenants/'"$ROGUE_CUSTOMER" \
    "non-stage1 customer never receives DELETE"

DB_LOG="$(cat "$WORK_DIR/staging_db_queries.log" 2>/dev/null || true)"
assert_contains "$DB_LOG" "$STAGING_VERIFY_CUSTOMER" \
    "staging list_http_404 customer requires staging_db_run_sql proof"

DISP_JSON="$RUN_OUT_DIR/runs/primary/30_stage5_soft_delete_dispositions.json"
assert_file_exists "$DISP_JSON" "stage5 disposition table is generated"

DISP_CONTENT="$(cat "$DISP_JSON")"
assert_contains "$DISP_CONTENT" "soft_deleted_via_admin_route" \
    "disposition table records soft_deleted_via_admin_route bucket"
assert_contains "$DISP_CONTENT" "already_deleted_confirmed" \
    "disposition table records already_deleted_confirmed bucket"
assert_not_contains "$DISP_CONTENT" "$ROGUE_CUSTOMER" \
    "non-stage1 customer excluded from disposition output"

SUMMARY_JSON="$RUN_OUT_DIR/runs/primary/40_stage5_soft_delete_summary.json"
assert_file_exists "$SUMMARY_JSON" "stage5 summary artifact is generated"
SUMMARY_CONTENT="$(cat "$SUMMARY_JSON")"
assert_contains "$SUMMARY_CONTENT" "active_exact_cleanup_customers" \
    "summary includes Stage 6 active_exact_cleanup_customers lineage"

run_test_summary
