#!/usr/bin/env bash
# Focused smoke coverage for scripts/customer_broadcast.sh wrapper contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

SERVER_PIDS=()

cleanup_servers() {
    local pid
    for pid in "${SERVER_PIDS[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup_servers EXIT

wait_for_file() {
    local path="$1"
    local timeout_secs="$2"
    local attempts=$((timeout_secs * 10))
    local i
    for ((i = 0; i < attempts; i++)); do
        if [ -f "$path" ]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

start_http_capture_server() {
    local tmp_dir="$1"
    local port_file="$tmp_dir/server_port"
    local request_meta_file="$tmp_dir/request_meta.json"
    local request_body_file="$tmp_dir/request_body.json"
    local server_script="$tmp_dir/http_capture_server.py"

    cat > "$server_script" <<'PYEOF'
import http.server
import json
import sys
from pathlib import Path

port_path = Path(sys.argv[1])
meta_path = Path(sys.argv[2])
body_path = Path(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        body_len = int(self.headers.get("Content-Length", "0"))
        body_raw = self.rfile.read(body_len).decode("utf-8")
        body_path.write_text(body_raw, encoding="utf-8")

        meta = {
            "method": self.command,
            "path": self.path,
            "x_admin_key": self.headers.get("x-admin-key", ""),
            "content_type": self.headers.get("Content-Type", ""),
        }
        meta_path.write_text(json.dumps(meta), encoding="utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"accepted":true}')

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_address[1]), encoding="utf-8")
server.handle_request()
PYEOF

    python3 "$server_script" "$port_file" "$request_meta_file" "$request_body_file" >"$tmp_dir/server.log" 2>&1 &
    local server_pid=$!
    SERVER_PIDS+=("$server_pid")

    if ! wait_for_file "$port_file" 5; then
        fail "capture server did not publish a port file"
        printf '%s %s\n' "$server_pid" ""
        return 1
    fi

    local server_port
    server_port="$(cat "$port_file")"
    printf '%s %s\n' "$server_pid" "$server_port"
}

assert_json_string_field() {
    local payload="$1"
    local field_name="$2"
    local expected="$3"
    local msg="$4"

    if python3 - "$payload" "$field_name" "$expected" <<'PYEOF'
import json
import sys
obj = json.loads(sys.argv[1])
field = sys.argv[2]
expected = sys.argv[3]
value = obj.get(field)
if value != expected:
    raise SystemExit(1)
PYEOF
    then
        pass "$msg"
    else
        fail "$msg (field '$field_name' mismatch)"
    fi
}

assert_json_field_absent() {
    local payload="$1"
    local field_name="$2"
    local msg="$3"

    if python3 - "$payload" "$field_name" <<'PYEOF'
import json
import sys
obj = json.loads(sys.argv[1])
field = sys.argv[2]
if field in obj:
    raise SystemExit(1)
PYEOF
    then
        pass "$msg"
    else
        fail "$msg (field '$field_name' should be absent)"
    fi
}

assert_meta_field() {
    local meta_json="$1"
    local field_name="$2"
    local expected="$3"
    local msg="$4"

    if python3 - "$meta_json" "$field_name" "$expected" <<'PYEOF'
import json
import sys
obj = json.loads(sys.argv[1])
field = sys.argv[2]
expected = sys.argv[3]
if obj.get(field) != expected:
    raise SystemExit(1)
PYEOF
    then
        pass "$msg"
    else
        fail "$msg (meta '$field_name' mismatch)"
    fi
}

remove_server_pid() {
    local target_pid="$1"
    local kept=()
    local pid
    for pid in "${SERVER_PIDS[@]:-}"; do
        if [ "$pid" != "$target_pid" ]; then
            kept+=("$pid")
        fi
    done
    SERVER_PIDS=("${kept[@]:-}")
}

stop_http_capture_server() {
    local server_pid="$1"
    if kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    else
        wait "$server_pid" 2>/dev/null || true
    fi
    remove_server_pid "$server_pid"
}

make_secret_file() {
    local path="$1"
    local port="$2"
    local admin_key="$3"

    cat > "$path" <<EOF_SECRET
API_URL=http://127.0.0.1:${port}
ADMIN_KEY=${admin_key}
EOF_SECRET
}

test_dry_run_text_body_posts_expected_payload_and_headers() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local server_pid server_port
    read -r server_pid server_port < <(start_http_capture_server "$tmp_dir")

    local secret_file="$tmp_dir/.env.secret"
    local admin_key="stage7_admin_key"
    make_secret_file "$secret_file" "$server_port" "$admin_key"

    local subject="Billing update: April"
    local text_body="Hello customer, this is a dry run."

    local output exit_code=0
    output="$(
        env -u API_URL -u ADMIN_KEY \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$REPO_ROOT/scripts/customer_broadcast.sh" \
            --subject "$subject" \
            --text-body "$text_body" \
            --dry-run 2>&1
    )" || exit_code=$?

    assert_eq "$exit_code" "0" "dry-run text-body invocation should succeed"
    assert_contains "$output" '"accepted":true' "wrapper should print server response body"

    if ! wait_for_file "$tmp_dir/request_body.json" 2; then
        fail "server should capture one request payload"
    else
        local payload meta
        payload="$(cat "$tmp_dir/request_body.json")"
        meta="$(cat "$tmp_dir/request_meta.json")"

        assert_valid_json "$payload" "payload should be valid JSON"
        assert_json_string_field "$payload" "subject" "$subject" "subject should be preserved exactly"
        assert_json_bool_field "$payload" "dry_run" "true" "dry_run should be true for --dry-run"
        assert_json_string_field "$payload" "text_body" "$text_body" "text_body should be serialized"
        assert_json_field_absent "$payload" "html_body" "html_body should be omitted when not provided"

        assert_meta_field "$meta" "method" "POST" "wrapper should use POST"
        assert_meta_field "$meta" "path" "/admin/broadcast" "request path should target /admin/broadcast"
        assert_meta_field "$meta" "x_admin_key" "$admin_key" "request should use x-admin-key header"
        assert_meta_field "$meta" "content_type" "application/json" "request should send JSON content type"
    fi

    stop_http_capture_server "$server_pid"
    rm -rf "$tmp_dir"
}

test_dry_run_html_body_omits_text_body() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local server_pid server_port
    read -r server_pid server_port < <(start_http_capture_server "$tmp_dir")

    local secret_file="$tmp_dir/.env.secret"
    local admin_key="stage7_admin_key_html"
    make_secret_file "$secret_file" "$server_port" "$admin_key"

    local subject="HTML broadcast"
    local html_body="<p>Welcome <strong>operators</strong></p>"

    local output exit_code=0
    output="$(
        env -u API_URL -u ADMIN_KEY \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$REPO_ROOT/scripts/customer_broadcast.sh" \
            --subject "$subject" \
            --html-body "$html_body" \
            --dry-run 2>&1
    )" || exit_code=$?

    assert_eq "$exit_code" "0" "dry-run html-body invocation should succeed"
    assert_contains "$output" '"accepted":true' "wrapper should print server response body for html payload"

    if ! wait_for_file "$tmp_dir/request_body.json" 2; then
        fail "server should capture html-body request payload"
    else
        local payload
        payload="$(cat "$tmp_dir/request_body.json")"
        assert_valid_json "$payload" "html payload should be valid JSON"
        assert_json_string_field "$payload" "subject" "$subject" "html case should preserve subject"
        assert_json_bool_field "$payload" "dry_run" "true" "html case should keep dry_run true"
        assert_json_string_field "$payload" "html_body" "$html_body" "html_body should be serialized"
        assert_json_field_absent "$payload" "text_body" "text_body should be omitted when not provided"
    fi

    stop_http_capture_server "$server_pid"
    rm -rf "$tmp_dir"
}

test_missing_subject_rejected_before_http_request() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local server_pid server_port
    read -r server_pid server_port < <(start_http_capture_server "$tmp_dir")

    local secret_file="$tmp_dir/.env.secret"
    make_secret_file "$secret_file" "$server_port" "stage7_missing_subject"

    local output exit_code=0
    output="$(
        env -u API_URL -u ADMIN_KEY \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$REPO_ROOT/scripts/customer_broadcast.sh" \
            --text-body "body without subject" 2>&1
    )" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "missing --subject should exit non-zero"
    else
        fail "missing --subject should not succeed"
    fi
    assert_contains "$output" "--subject is required" "missing --subject should emit validation error"

    if [ -f "$tmp_dir/request_body.json" ]; then
        fail "missing --subject should fail before sending any request"
    else
        pass "missing --subject should not reach HTTP stub"
    fi

    stop_http_capture_server "$server_pid"
    rm -rf "$tmp_dir"
}

test_text_body_and_file_are_mutually_exclusive() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local server_pid server_port
    read -r server_pid server_port < <(start_http_capture_server "$tmp_dir")

    local secret_file="$tmp_dir/.env.secret"
    make_secret_file "$secret_file" "$server_port" "stage7_body_conflict"

    local body_file="$tmp_dir/body.txt"
    cat > "$body_file" <<'EOF_BODY'
Body from file
EOF_BODY

    local output exit_code=0
    output="$(
        env -u API_URL -u ADMIN_KEY \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$REPO_ROOT/scripts/customer_broadcast.sh" \
            --subject "Conflict case" \
            --text-body "inline body" \
            --text-body-file "$body_file" 2>&1
    )" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        pass "text-body and text-body-file conflict should exit non-zero"
    else
        fail "text-body and text-body-file conflict should fail"
    fi
    assert_contains "$output" "--text-body and --text-body-file cannot be combined" "conflict should emit validation error"

    if [ -f "$tmp_dir/request_body.json" ]; then
        fail "mutually exclusive text body inputs should reject before HTTP request"
    else
        pass "mutually exclusive text body inputs should not reach HTTP stub"
    fi

    stop_http_capture_server "$server_pid"
    rm -rf "$tmp_dir"
}

main() {
    echo "=== customer_broadcast smoke tests ==="

    test_dry_run_text_body_posts_expected_payload_and_headers
    test_dry_run_html_body_omits_text_body
    test_missing_subject_rejected_before_http_request
    test_text_body_and_file_are_mutually_exclusive

    run_test_summary
}

main "$@"
