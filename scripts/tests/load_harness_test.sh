#!/usr/bin/env bash
# Tests for scripts/load/lib/load_checks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

_write_metrics_json() {
    local path="$1" endpoint="$2" p50="$3" p95="$4" p99="$5" throughput="$6" error_rate="$7"
    cat > "$path" <<JSON
{
  "endpoint": "$endpoint",
  "timestamp": "2026-03-04T00:00:00Z",
  "concurrency": 10,
  "duration_sec": 30,
  "latency_p50_ms": $p50,
  "latency_p95_ms": $p95,
  "latency_p99_ms": $p99,
  "throughput_rps": $throughput,
  "error_rate": $error_rate,
  "meta": {"source": "test"}
}
JSON
}

_run_compare() {
    local result_path="$1" baseline_path="$2"
    local output exit_code=0

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/load/lib/load_checks.sh'
        compare_against_baseline '$result_path' '$baseline_path'
    " 2>&1)" || exit_code=$?

    COMPARE_EXIT_CODE="$exit_code"
    COMPARE_OUTPUT="$output"
}

# Shared mock k6 that logs args, writes a standard summary JSON, and exits.
# Usage: _write_mock_k6_with_summary <path> [log_args=1] [exit_code=0]
_write_mock_k6_with_summary() {
    local path="$1" log_args="${2:-1}" exit_code="${3:-0}"
    cat > "$path" <<'MOCK_HEADER'
#!/usr/bin/env bash
set -euo pipefail
MOCK_HEADER
    if [ "$log_args" = "1" ]; then
        echo 'echo "$*" >> "$MOCK_K6_LOG"' >> "$path"
    fi
    cat >> "$path" <<'MOCK_BODY'
summary_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in --summary-export) summary_file="$2"; shift 2 ;; *) shift ;; esac
done
cat > "$summary_file" <<'JSON'
{
  "metrics": {
    "http_req_duration": { "p(50)": 10, "p(95)": 20, "p(99)": 30 },
    "http_reqs": { "count": 4200, "rate": 100 },
    "http_req_failed": { "value": 0.0 },
    "vus_max": { "value": 7 }
  }
}
JSON
MOCK_BODY
    if [ "$exit_code" != "0" ]; then
        echo "exit $exit_code" >> "$path"
    fi
    chmod +x "$path"
}

# Simple mock k6 that logs args and exits. No summary output.
# Usage: _write_mock_k6_noop <path> [exit_code=0]
_write_mock_k6_noop() {
    local path="$1" exit_code="${2:-0}"
    cat > "$path" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
echo "\$*" >> "\$MOCK_K6_LOG"
exit $exit_code
MOCK
    chmod +x "$path"
}

_write_mock_curl_for_stale_user_recovery() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
method="GET"
url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            body_file="$2"
            shift 2
            ;;
        -w)
            shift 2
            ;;
        --request)
            method="$2"
            shift 2
            ;;
        --url)
            url="$2"
            shift 2
            ;;
        -H|-d)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

mkdir -p "$MOCK_CURL_STATE_DIR"

counter_file() {
    printf '%s/%s.count\n' "$MOCK_CURL_STATE_DIR" "$1"
}

next_count() {
    local name="$1"
    local file
    file="$(counter_file "$name")"
    local count=0
    if [ -f "$file" ]; then
        count="$(cat "$file")"
    fi
    count=$((count + 1))
    printf '%s' "$count" > "$file"
    printf '%s' "$count"
}

status="500"
body='{"error":"unexpected mock curl request"}'

case "$method $url" in
    "GET http://localhost:3001/health"|"GET http://localhost:7700/health")
        status="200"
        body='{"status":"ok"}'
        ;;
    "POST http://localhost:3001/auth/login")
        next_count "login" >/dev/null
        status="400"
        body='{"error":"invalid email or password"}'
        ;;
    "POST http://localhost:3001/auth/register")
        register_count="$(next_count "register")"
        if [ "$register_count" = "1" ]; then
            status="409"
            body='{"error":"email already exists"}'
        else
            status="201"
            body='{"token":"jwt-created"}'
        fi
        ;;
    "GET http://localhost:3001/admin/tenants")
        next_count "list_tenants" >/dev/null
        status="200"
        body='[{"id":"stale-customer","name":"Local Load Harness","email":"stale-load@example.com","status":"active","billing_plan":"free"}]'
        ;;
    "DELETE http://localhost:3001/admin/tenants/stale-customer")
        next_count "delete_tenant" >/dev/null
        status="204"
        body=''
        ;;
    "GET http://localhost:3001/account")
        status="200"
        body='{"id":"cust-123"}'
        ;;
    "PUT http://localhost:3001/admin/tenants/cust-123")
        status="200"
        body='{"id":"cust-123"}'
        ;;
    "GET http://localhost:3001/indexes")
        status="200"
        body='[]'
        ;;
    "POST http://localhost:3001/indexes")
        status="201"
        body='{"created":true}'
        ;;
    "POST http://localhost:3001/indexes/test-load-index/search")
        status="200"
        body='{"hits":[]}'
        ;;
esac

if [ -n "$body_file" ]; then
    printf '%s' "$body" > "$body_file"
fi
printf '%s' "$status"
MOCK
    chmod +x "$path"
}

_write_mock_curl_for_deleted_email_conflict() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
method="GET"
url=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            body_file="$2"
            shift 2
            ;;
        -w)
            shift 2
            ;;
        --request)
            method="$2"
            shift 2
            ;;
        --url)
            url="$2"
            shift 2
            ;;
        -H|-d)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

mkdir -p "$MOCK_CURL_STATE_DIR"

counter_file() {
    printf '%s/%s.count\n' "$MOCK_CURL_STATE_DIR" "$1"
}

next_count() {
    local name="$1"
    local file
    file="$(counter_file "$name")"
    local count=0
    if [ -f "$file" ]; then
        count="$(cat "$file")"
    fi
    count=$((count + 1))
    printf '%s' "$count" > "$file"
    printf '%s' "$count"
}

status="500"
body='{"error":"unexpected mock curl request"}'

case "$method $url" in
    "GET http://localhost:3001/health"|"GET http://localhost:7700/health")
        status="200"
        body='{"status":"ok"}'
        ;;
    "POST http://localhost:3001/auth/login")
        next_count "login" >/dev/null
        status="400"
        body='{"error":"invalid email or password"}'
        ;;
    "POST http://localhost:3001/auth/register")
        register_count="$(next_count "register")"
        if [ "$register_count" = "1" ]; then
            status="409"
            body='{"error":"email already exists"}'
        else
            status="201"
            body='{"token":"jwt-created"}'
        fi
        ;;
    "GET http://localhost:3001/admin/tenants")
        next_count "list_tenants" >/dev/null
        status="200"
        body='[{"id":"deleted-customer","name":"Local Load Harness","email":"stale-load@example.com","status":"deleted","billing_plan":"free"}]'
        ;;
    "GET http://localhost:3001/account")
        status="200"
        body='{"id":"cust-123"}'
        ;;
    "PUT http://localhost:3001/admin/tenants/cust-123")
        status="200"
        body='{"id":"cust-123"}'
        ;;
    "GET http://localhost:3001/indexes")
        status="200"
        body='[]'
        ;;
    "POST http://localhost:3001/indexes")
        status="201"
        body='{"created":true}'
        ;;
    "POST http://localhost:3001/indexes/test-load-index/search")
        status="200"
        body='{"hits":[]}'
        ;;
esac

if [ -n "$body_file" ]; then
    printf '%s' "$body" > "$body_file"
fi
printf '%s' "$status"
MOCK
    chmod +x "$path"
}

test_compare_baselines_passes_within_threshold() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 20 100 140 200 0.001
    _write_metrics_json "$result" "search_query" 22 115 150 185 0.001

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "compare_against_baseline should pass at 15% delta"
    assert_contains "$output" "LOAD_BASELINE_PASS" "compare_against_baseline should emit LOAD_BASELINE_PASS"
}

test_compare_baselines_detects_regression_warning() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 200 300 420 200 0.001
    _write_metrics_json "$result" "search_query" 220 375 465 185 0.001

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "compare_against_baseline should warn at 25% latency regression"
    assert_contains "$output" "LOAD_REGRESSION_WARNING" "compare_against_baseline should emit LOAD_REGRESSION_WARNING"
}

test_compare_baselines_ignores_small_absolute_latency_drift() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 16 20 0 5 0.0
    _write_metrics_json "$result" "search_query" 19 55 0 4.9 0.0

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "compare_against_baseline should ignore low-latency drift within the absolute slack"
    assert_contains "$output" "LOAD_BASELINE_PASS" "low-latency drift within the absolute slack should still emit LOAD_BASELINE_PASS"
}

test_compare_baselines_detects_regression_failure() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 20 100 140 200 0.001
    _write_metrics_json "$result" "search_query" 25 155 220 170 0.001

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "compare_against_baseline should fail at 55% latency regression"
    assert_contains "$output" "LOAD_REGRESSION_FAILURE" "compare_against_baseline should emit LOAD_REGRESSION_FAILURE"
}

test_compare_baselines_skip_when_no_baseline() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/missing_baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$result" "search_query" 20 100 140 200 0.001

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "compare_against_baseline should skip when baseline is missing"
    assert_contains "$output" "LOAD_BASELINE_SKIP" "compare_against_baseline should emit LOAD_BASELINE_SKIP"
}

test_compare_baselines_throughput_regression() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 20 100 140 200 0.001
    _write_metrics_json "$result" "search_query" 20 100 140 90 0.001

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "compare_against_baseline should fail when throughput drops by 55%"
    assert_contains "$output" "LOAD_REGRESSION_FAILURE" "throughput regression should emit LOAD_REGRESSION_FAILURE"
}

test_compare_baselines_error_rate_regression() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 20 100 140 200 0.005
    _write_metrics_json "$result" "search_query" 20 100 140 200 0.06

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "compare_against_baseline should fail when error rate exceeds 5%"
    assert_contains "$output" "LOAD_REGRESSION_FAILURE" "error-rate regression should emit LOAD_REGRESSION_FAILURE"
}

test_compare_baselines_fails_when_k6_thresholds_failed() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    local baseline="$tmpdir/baseline.json"
    local result="$tmpdir/result.json"
    _write_metrics_json "$baseline" "search_query" 20 100 140 200 0.001
    _write_metrics_json "$result" "search_query" 20 100 140 200 0.001

    python3 - "$result" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data.setdefault("meta", {})["k6_status"] = "threshold_fail"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

    _run_compare "$result" "$baseline"
    local exit_code="$COMPARE_EXIT_CODE"
    local output="$COMPARE_OUTPUT"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "compare_against_baseline should fail when k6 thresholds already failed"
    assert_contains "$output" "LOAD_K6_THRESHOLD_FAILURE" "threshold failure should emit LOAD_K6_THRESHOLD_FAILURE"
}

_copy_seed_baselines() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    cp "$REPO_ROOT/scripts/load/baselines/health.json" "$dest_dir/health.json"
    cp "$REPO_ROOT/scripts/load/baselines/search_query.json" "$dest_dir/search_query.json"
    cp "$REPO_ROOT/scripts/load/baselines/index_create.json" "$dest_dir/index_create.json"
    cp "$REPO_ROOT/scripts/load/baselines/admin_tenant_list.json" "$dest_dir/admin_tenant_list.json"
    cp "$REPO_ROOT/scripts/load/baselines/document_ingestion.json" "$dest_dir/document_ingestion.json"
}

_write_uniform_baselines() {
    local dest_dir="$1" p50="$2" p95="$3" p99="$4" throughput="$5" error_rate="$6"
    mkdir -p "$dest_dir"
    _write_metrics_json "$dest_dir/health.json" "health" "$p50" "$p95" "$p99" "$throughput" "$error_rate"
    _write_metrics_json "$dest_dir/search_query.json" "search_query" "$p50" "$p95" "$p99" "$throughput" "$error_rate"
    _write_metrics_json "$dest_dir/index_create.json" "index_create" "$p50" "$p95" "$p99" "$throughput" "$error_rate"
    _write_metrics_json "$dest_dir/admin_tenant_list.json" "admin_tenant_list" "$p50" "$p95" "$p99" "$throughput" "$error_rate"
    _write_metrics_json "$dest_dir/document_ingestion.json" "document_ingestion" "$p50" "$p95" "$p99" "$throughput" "$error_rate"
}

_json_field() {
    local json="$1" field="$2"
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d['$field']))" <<< "$json"
}

_run_load_gate() {
    local baseline_dir="$1" result_dir="$2"
    local output exit_code=0

    output="$(BACKEND_LIVE_GATE=1 LOAD_BASELINE_DIR="$baseline_dir" LOAD_RESULT_DIR="$result_dir" bash -c "
        source '$REPO_ROOT/scripts/load/lib/load_checks.sh'
        run_load_gate
    " 2>/dev/null)" || exit_code=$?

    LOAD_GATE_EXIT_CODE="$exit_code"
    LOAD_GATE_OUTPUT="$output"
}

test_run_load_gate_produces_valid_json() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines" result_dir="$tmpdir/results"
    _copy_seed_baselines "$baseline_dir"
    _copy_seed_baselines "$result_dir"

    _run_load_gate "$baseline_dir" "$result_dir"
    local exit_code="$LOAD_GATE_EXIT_CODE"
    local output="$LOAD_GATE_OUTPUT"

    local valid
    valid="$(echo "$output" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "run_load_gate should exit 0 in offline mode"
    assert_eq "$valid" "yes" "run_load_gate should produce valid JSON"
    assert_contains "$output" "\"check_results\"" "run_load_gate JSON should include check_results"
    assert_contains "$output" "\"checks_run\"" "run_load_gate JSON should include checks_run"
    assert_contains "$output" "\"passed\"" "run_load_gate JSON should include passed"
    assert_contains "$output" "\"elapsed_ms\"" "run_load_gate JSON should include elapsed_ms"
    assert_contains "$output" "\"failures\"" "run_load_gate JSON should include failures"
}

test_run_load_gate_all_pass_with_baselines() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines" result_dir="$tmpdir/results"
    _copy_seed_baselines "$baseline_dir"
    _copy_seed_baselines "$result_dir"

    _run_load_gate "$baseline_dir" "$result_dir"
    local output="$LOAD_GATE_OUTPUT"

    local passed checks_failed
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"

    rm -rf "$tmpdir"

    assert_eq "$passed" "true" "run_load_gate should pass when all endpoints are within threshold"
    assert_eq "$checks_failed" "0" "run_load_gate should report checks_failed=0 when all pass"
}

test_run_load_gate_reports_regression() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines" result_dir="$tmpdir/results"
    _copy_seed_baselines "$baseline_dir"
    _copy_seed_baselines "$result_dir"

    python3 - "$result_dir/search_query.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["latency_p95_ms"] = int(round(data["latency_p95_ms"] * 4.5))
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

    _run_load_gate "$baseline_dir" "$result_dir"
    local output="$LOAD_GATE_OUTPUT"

    local passed
    passed="$(_json_field "$output" passed)"
    local has_failure
    has_failure="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(any('search_query' in item for item in d.get('failures', [])))" <<< "$output")"

    rm -rf "$tmpdir"

    assert_eq "$passed" "false" "run_load_gate should fail when one endpoint regresses >50%"
    assert_eq "$has_failure" "True" "run_load_gate failures should include regressed endpoint"
}

test_run_load_gate_warning_does_not_fail() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines" result_dir="$tmpdir/results"
    _copy_seed_baselines "$baseline_dir"
    _copy_seed_baselines "$result_dir"

    python3 - "$result_dir/admin_tenant_list.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["latency_p95_ms"] = int(round(data["latency_p95_ms"] * 1.25))
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

    _run_load_gate "$baseline_dir" "$result_dir"
    local output="$LOAD_GATE_OUTPUT"

    local passed checks_failed has_warning
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    has_warning="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(any(item.get('reason') == 'LOAD_REGRESSION_WARNING' for item in d.get('check_results', [])))" <<< "$output")"

    rm -rf "$tmpdir"

    assert_eq "$passed" "true" "run_load_gate should remain passing when only warnings occur"
    assert_eq "$checks_failed" "0" "run_load_gate should report checks_failed=0 when only warnings occur"
    assert_eq "$has_warning" "True" "run_load_gate should retain warning reason in check_results"
}

test_run_load_harness_live_mode_applies_configurable_vus_and_duration() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    _write_mock_k6_with_summary "$mock_bin/k6"

    local output exit_code=0
    output="$(MOCK_K6_LOG="$mock_k6_log" \
        PATH="$mock_bin:$PATH" \
        LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        LOAD_K6_CONCURRENCY=7 \
        LOAD_K6_DURATION_SEC=42 \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        bash "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed invocations log_contents
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    invocations="$(wc -l < "$mock_k6_log" | tr -d ' ')"
    log_contents="$(cat "$mock_k6_log")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "run_load_harness live mode should pass with matching baselines"
    assert_eq "$passed" "true" "run_load_harness live mode should report passed=true with matching baselines"
    assert_eq "$checks_failed" "0" "run_load_harness live mode should report checks_failed=0 with matching baselines"
    assert_eq "$invocations" "5" "run_load_harness live mode should execute k6 once per endpoint"
    assert_contains "$log_contents" "--vus 7" "run_load_harness should pass LOAD_K6_CONCURRENCY to k6 as --vus"
    assert_contains "$log_contents" "--duration 42s" "run_load_harness should pass LOAD_K6_DURATION_SEC to k6 as --duration"
}

test_run_load_harness_live_mode_defaults_to_local_fixed_profile() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    cat > "$mock_bin/k6" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_K6_LOG"
summary_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --summary-export)
            summary_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cat > "$summary_file" <<'JSON'
{
  "metrics": {
    "http_req_duration": {
      "med": 10,
      "p(95)": 20,
      "p(99)": 30
    },
    "http_reqs": {
      "count": 6000,
      "rate": 100
    },
    "http_req_failed": {
      "value": 0.0
    },
    "vus_max": {
      "value": 30
    }
  }
}
JSON
SH
    chmod +x "$mock_bin/k6"

    local output exit_code=0
    output="$(MOCK_K6_LOG="$mock_k6_log" \
        PATH="$mock_bin:$PATH" \
        LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        bash "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed log_contents
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    log_contents="$(cat "$mock_k6_log")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "run_load_harness live mode should pass with the default local_fixed profile"
    assert_eq "$passed" "true" "run_load_harness should report passed=true with the default local_fixed profile"
    assert_eq "$checks_failed" "0" "run_load_harness should report checks_failed=0 with the default local_fixed profile"
    assert_contains "$log_contents" "--vus 5" "run_load_harness should default local_fixed profile concurrency to 5 VUs"
    assert_contains "$log_contents" "--duration 45s" "run_load_harness should default local_fixed profile duration to 45s"
}

test_run_load_harness_live_mode_allows_explicit_script_profile() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    cat > "$mock_bin/k6" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$MOCK_K6_LOG"
summary_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --summary-export)
            summary_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
cat > "$summary_file" <<'JSON'
{
  "metrics": {
    "http_req_duration": {
      "med": 10,
      "p(95)": 20,
      "p(99)": 30
    },
    "http_reqs": {
      "count": 6000,
      "rate": 100
    },
    "http_req_failed": {
      "value": 0.0
    },
    "vus_max": {
      "value": 30
    }
  }
}
JSON
SH
    chmod +x "$mock_bin/k6"

    local output exit_code=0
    output="$(MOCK_K6_LOG="$mock_k6_log" \
        PATH="$mock_bin:$PATH" \
        LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        LOAD_K6_MODE=script \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        bash "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed log_contents
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    log_contents="$(cat "$mock_k6_log")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "run_load_harness live mode should allow explicit script mode"
    assert_eq "$passed" "true" "run_load_harness should report passed=true in explicit script mode"
    assert_eq "$checks_failed" "0" "run_load_harness should report checks_failed=0 in explicit script mode"
    if [[ "$log_contents" == *"--vus"* ]]; then
        fail "run_load_harness should not pass --vus in explicit script mode"
    else
        pass "run_load_harness should omit --vus in explicit script mode"
    fi
    if [[ "$log_contents" == *"--duration"* ]]; then
        fail "run_load_harness should not pass --duration in explicit script mode"
    else
        pass "run_load_harness should omit --duration in explicit script mode"
    fi
}

test_run_load_harness_live_mode_keeps_summary_when_k6_thresholds_fail() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    _write_mock_k6_with_summary "$mock_bin/k6" 0 99

    local output exit_code=0
    output="$(PATH="$mock_bin:$PATH" \
        LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        LOAD_K6_CONCURRENCY=7 \
        LOAD_K6_DURATION_SEC=42 \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        bash "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed reason
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    reason="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0]['reason'])" <<< "$output")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "run_load_harness should fail when k6 exports a summary with threshold failures"
    assert_eq "$passed" "false" "run_load_harness should report passed=false when script thresholds fail"
    assert_eq "$checks_failed" "5" "run_load_harness should report each threshold-failed endpoint as failed"
    assert_eq "$reason" "LOAD_K6_THRESHOLD_FAILURE" "run_load_harness should preserve threshold failures in structured JSON"
}

test_run_load_harness_live_mode_skips_when_k6_missing() {
    local path_without_k6=""
    local old_ifs="$IFS"
    local dir
    IFS=':'
    for dir in $PATH; do
        if [ -n "$dir" ] && [ -x "$dir/k6" ]; then
            continue
        fi
        if [ -z "$path_without_k6" ]; then
            path_without_k6="$dir"
        else
            path_without_k6="${path_without_k6}:$dir"
        fi
    done
    IFS="$old_ifs"
    if [ -z "$path_without_k6" ]; then
        path_without_k6="$PATH"
    fi

    local output exit_code=0
    output="$(PATH="$path_without_k6" \
        LOAD_GATE_LIVE=1 \
        "$BASH" "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_run checks_skipped reason error_class
    passed="$(_json_field "$output" passed)"
    checks_run="$(_json_field "$output" checks_run)"
    checks_skipped="$(_json_field "$output" checks_skipped)"
    reason="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0]['reason'])" <<< "$output")"
    error_class="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0].get('error_class', ''))" <<< "$output")"

    assert_eq "$exit_code" "0" "run_load_harness should exit 0 when k6 is missing in live mode"
    assert_eq "$passed" "true" "run_load_harness should keep passed=true when live mode skips for missing k6"
    assert_eq "$checks_run" "0" "run_load_harness should report checks_run=0 when k6 is missing"
    assert_eq "$checks_skipped" "1" "run_load_harness should report checks_skipped=1 when k6 is missing"
    assert_eq "$reason" "LOAD_K6_SKIP_TOOL_MISSING" "run_load_harness should emit LOAD_K6_SKIP_TOOL_MISSING when k6 is missing"
    assert_eq "$error_class" "precondition" "run_load_harness should classify missing k6 as precondition"
}

test_run_load_harness_live_mode_fails_when_local_prep_is_not_runnable() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    _write_mock_k6_noop "$mock_bin/k6"

    local output exit_code=0
    output="$(PATH="$mock_bin:$PATH" \
        MOCK_K6_LOG="$mock_k6_log" \
        LOAD_GATE_LIVE=1 \
        LOAD_PREPARE_LOCAL=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        "$BASH" "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed reason error_class failures k6_calls=0
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    reason="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0]['reason'])" <<< "$output")"
    error_class="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0].get('error_class', ''))" <<< "$output")"
    failures="$(_json_field "$output" failures)"
    if [ -f "$mock_k6_log" ]; then
        k6_calls="$(wc -l < "$mock_k6_log" | tr -d ' ')"
    fi

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "run_load_harness should fail when local prep cannot execute"
    assert_eq "$passed" "false" "run_load_harness should report passed=false when local prep cannot execute"
    assert_eq "$checks_failed" "1" "run_load_harness should report one failed prerequisite check when local prep cannot execute"
    assert_eq "$reason" "LOAD_LOCAL_PREP_FAILURE" "run_load_harness should emit LOAD_LOCAL_PREP_FAILURE when local prep cannot execute"
    assert_eq "$error_class" "precondition" "run_load_harness should classify local prep execution failure as precondition"
    assert_contains "$failures" "load_live_prerequisites" "run_load_harness should keep failure list for local prep precondition failures"
    assert_eq "$k6_calls" "0" "run_load_harness should fail local prep before invoking k6"
}

test_run_load_harness_live_mode_fails_when_k6_mode_invalid() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    _write_mock_k6_noop "$mock_bin/k6"

    local output exit_code=0
    output="$(PATH="$mock_bin:$PATH" \
        MOCK_K6_LOG="$mock_k6_log" \
        LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        LOAD_K6_MODE="invalid_profile" \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        "$BASH" "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed reason error_class failures k6_calls=0
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    reason="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0]['reason'])" <<< "$output")"
    error_class="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0].get('error_class', ''))" <<< "$output")"
    failures="$(_json_field "$output" failures)"
    if [ -f "$mock_k6_log" ]; then
        k6_calls="$(wc -l < "$mock_k6_log" | tr -d ' ')"
    fi

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "run_load_harness should fail when LOAD_K6_MODE is invalid"
    assert_eq "$passed" "false" "run_load_harness should report passed=false for invalid LOAD_K6_MODE"
    assert_eq "$checks_failed" "1" "run_load_harness should report one failed check for invalid LOAD_K6_MODE"
    assert_eq "$reason" "LOAD_K6_MODE_INVALID" "run_load_harness should emit LOAD_K6_MODE_INVALID for invalid mode"
    assert_eq "$error_class" "precondition" "run_load_harness should classify invalid mode as precondition"
    assert_contains "$failures" "load_live_prerequisites" "run_load_harness should keep failure list for invalid mode precondition"
    assert_eq "$k6_calls" "0" "run_load_harness should reject invalid mode before invoking k6"
}

test_run_load_harness_live_mode_fails_when_k6_runtime_fails() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    _write_mock_k6_noop "$mock_bin/k6" 2

    local output exit_code=0
    output="$(PATH="$mock_bin:$PATH" \
        MOCK_K6_LOG="$mock_k6_log" \
        LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        LOAD_K6_MODE="fixed" \
        LOAD_K6_CONCURRENCY=3 \
        LOAD_K6_DURATION_SEC=15 \
        JWT="test-jwt" \
        INDEX_NAME="test-index" \
        ADMIN_KEY="test-admin-key" \
        "$BASH" "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed reason error_class failures k6_calls
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    reason="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0]['reason'])" <<< "$output")"
    error_class="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0].get('error_class', ''))" <<< "$output")"
    failures="$(_json_field "$output" failures)"
    k6_calls="$(wc -l < "$mock_k6_log" | tr -d ' ')"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "run_load_harness should fail when k6 exits with a runtime error"
    assert_eq "$passed" "false" "run_load_harness should report passed=false when k6 runtime fails"
    assert_eq "$checks_failed" "1" "run_load_harness should report one failed runtime check when k6 exits unexpectedly"
    assert_eq "$reason" "LOAD_K6_RUNTIME_FAILURE" "run_load_harness should emit LOAD_K6_RUNTIME_FAILURE for unexpected k6 exits"
    assert_eq "$error_class" "runtime" "run_load_harness should classify unexpected k6 exits as runtime"
    assert_contains "$failures" "load_k6_live_execution" "run_load_harness should include load_k6_live_execution in failures for runtime errors"
    assert_eq "$k6_calls" "1" "run_load_harness should stop after the first endpoint when k6 runtime fails"
}

test_run_load_harness_live_mode_fails_when_env_missing() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    _write_uniform_baselines "$baseline_dir" 10 20 30 100 0.0

    local output exit_code=0
    output="$(LOAD_GATE_LIVE=1 \
        LOAD_BASELINE_DIR="$baseline_dir" \
        "$BASH" "$REPO_ROOT/scripts/load/run_load_harness.sh" 2>/dev/null)" || exit_code=$?

    local passed checks_failed reason error_class
    passed="$(_json_field "$output" passed)"
    checks_failed="$(_json_field "$output" checks_failed)"
    reason="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0]['reason'])" <<< "$output")"
    error_class="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['check_results'][0].get('error_class', ''))" <<< "$output")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "run_load_harness should fail when live env prerequisites are missing"
    assert_eq "$passed" "false" "run_load_harness should report passed=false when live env prerequisites are missing"
    assert_eq "$checks_failed" "1" "run_load_harness should report one failed prerequisite check when live env is missing"
    assert_eq "$reason" "LOAD_LIVE_ENV_MISSING" "run_load_harness should emit LOAD_LIVE_ENV_MISSING when required env vars are absent"
    assert_eq "$error_class" "precondition" "run_load_harness should classify missing live env vars as precondition"
}

test_setup_local_prereqs_recovers_from_stale_user_password_drift() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    _write_mock_curl_for_stale_user_recovery "$mock_bin/curl"

    local output exit_code=0
    output="$(PATH="$mock_bin:$PATH" \
        MOCK_CURL_STATE_DIR="$tmpdir/state" \
        API_URL="http://localhost:3001" \
        BASE_URL="http://localhost:3001" \
        LOCAL_DEV_FLAPJACK_URL="http://localhost:7700" \
        ADMIN_KEY="test-admin-key" \
        LOAD_USER_EMAIL="stale-load@example.com" \
        LOAD_USER_PASSWORD="obsolete-password" \
        LOAD_USER_NAME="Local Load Harness" \
        LOAD_SETUP_DELETE_STALE_USER="1" \
        INDEX_NAME="test-load-index" \
        LOAD_INDEX_REGION="us-east-1" \
        bash "$REPO_ROOT/scripts/load/setup-local-prereqs.sh" 2>&1)" || exit_code=$?

    local register_count delete_count
    register_count="$(cat "$tmpdir/state/register.count")"
    delete_count="$(cat "$tmpdir/state/delete_tenant.count")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "setup-local-prereqs should recover when the stale load user password is obsolete"
    assert_contains "$output" "Deleted stale load user stale-load@example.com" "setup-local-prereqs should log stale-user deletion"
    assert_contains "$output" "export JWT=jwt-created" "setup-local-prereqs should emit the recreated user JWT"
    assert_contains "$output" "export INDEX_NAME=test-load-index" "setup-local-prereqs should export the prepared index name"
    assert_eq "$register_count" "2" "setup-local-prereqs should retry registration after deleting the stale user"
    assert_eq "$delete_count" "1" "setup-local-prereqs should soft-delete the stale tenant exactly once"
}

test_setup_local_prereqs_rotates_email_when_deleted_user_blocks_recreation() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"
    _write_mock_curl_for_deleted_email_conflict "$mock_bin/curl"

    local output exit_code=0
    output="$(PATH="$mock_bin:$PATH" \
        MOCK_CURL_STATE_DIR="$tmpdir/state" \
        API_URL="http://localhost:3001" \
        BASE_URL="http://localhost:3001" \
        LOCAL_DEV_FLAPJACK_URL="http://localhost:7700" \
        ADMIN_KEY="test-admin-key" \
        LOAD_USER_EMAIL="stale-load@example.com" \
        LOAD_USER_NAME="Local Load Harness" \
        INDEX_NAME="test-load-index" \
        LOAD_INDEX_REGION="us-east-1" \
        bash "$REPO_ROOT/scripts/load/setup-local-prereqs.sh" 2>&1)" || exit_code=$?

    local register_count list_count
    register_count="$(cat "$tmpdir/state/register.count")"
    list_count="$(cat "$tmpdir/state/list_tenants.count")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "setup-local-prereqs should recover when a deleted tenant still reserves the canonical email"
    assert_contains "$output" "Soft-deleted load user stale-load@example.com still reserves that email; rotating to" "setup-local-prereqs should log deleted-email rotation"
    assert_contains "$output" "export JWT=jwt-created" "setup-local-prereqs should emit the recreated user JWT after rotating email"
    assert_contains "$output" "export LOAD_USER_EMAIL=stale-load+recreated-" "setup-local-prereqs should export the rotated load email"
    assert_eq "$register_count" "2" "setup-local-prereqs should retry registration after rotating the blocked email"
    assert_eq "$list_count" "2" "setup-local-prereqs should inspect tenants for active and deleted-email conflict states"
}

test_sla_baseline_runbook_matches_live_contract() {
    local runbook="$REPO_ROOT/docs/load-testing/sla-baseline.md"
    local content
    content="$(cat "$runbook")"

    local required_tokens=(
        "run_live_mode()" "bash scripts/load/run_load_harness.sh" "LOAD_TARGET_ENDPOINTS" "health" "search_query" "index_create"
        "admin_tenant_list" "document_ingestion" "authoritative local signoff path uses the \`local_fixed\` profile by default" "Set \`LOAD_K6_MODE=script\`"
        "not the authoritative local signoff path" "local_fixed" "staged" "LOAD_PREPARE_LOCAL=1"
        "LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS=1" "k6_status" "approved_local" "LOAD_BASELINE_PASS"
        "LOAD_REGRESSION_WARNING" "LOAD_REGRESSION_FAILURE" "LOAD_K6_THRESHOLD_FAILURE" "LOAD_K6_SKIP_TOOL_MISSING"
        "LOAD_LOCAL_PREP_FAILURE" "LOAD_LIVE_ENV_MISSING" "LOAD_K6_MODE_INVALID" "LOAD_K6_RUNTIME_FAILURE"
    )
    local forbidden_tokens=("placeholder seed" "## Open Questions")
    local token

    for token in "${required_tokens[@]}"; do
        assert_contains "$content" "$token" "runbook should mention $token"
    done

    for token in "${forbidden_tokens[@]}"; do
        if [[ "$content" == *"$token"* ]]; then
            fail "runbook should not mention $token"
        else
            pass "runbook should not mention $token"
        fi
    done
}

test_setup_local_prereqs_has_executable_mode() {
    # The load harness invokes setup-local-prereqs.sh directly, so it must
    # have executable mode in the working tree (which mirrors git index mode).
    if [ -x "$REPO_ROOT/scripts/load/setup-local-prereqs.sh" ]; then
        pass "setup-local-prereqs.sh has executable file mode"
    else
        fail "setup-local-prereqs.sh should have executable file mode (currently not executable)"
    fi
}

echo "=== load_harness tests ==="
echo ""
echo "--- compare_against_baseline core tests ---"
test_compare_baselines_passes_within_threshold
test_compare_baselines_detects_regression_warning
test_compare_baselines_detects_regression_failure
test_compare_baselines_skip_when_no_baseline
echo ""
echo "--- compare_against_baseline edge-case tests ---"
test_compare_baselines_throughput_regression
test_compare_baselines_error_rate_regression
test_compare_baselines_fails_when_k6_thresholds_failed
echo ""
echo "--- run_load_gate tests ---"
test_run_load_gate_produces_valid_json
test_run_load_gate_all_pass_with_baselines
test_run_load_gate_reports_regression
test_run_load_gate_warning_does_not_fail
echo ""
echo "--- run_load_harness tests ---"
test_run_load_harness_live_mode_applies_configurable_vus_and_duration
test_run_load_harness_live_mode_defaults_to_local_fixed_profile
test_run_load_harness_live_mode_allows_explicit_script_profile
test_run_load_harness_live_mode_keeps_summary_when_k6_thresholds_fail
test_run_load_harness_live_mode_skips_when_k6_missing
test_run_load_harness_live_mode_fails_when_local_prep_is_not_runnable
test_run_load_harness_live_mode_fails_when_k6_mode_invalid
test_run_load_harness_live_mode_fails_when_k6_runtime_fails
test_run_load_harness_live_mode_fails_when_env_missing
test_setup_local_prereqs_recovers_from_stale_user_password_drift
test_setup_local_prereqs_rotates_email_when_deleted_user_blocks_recreation
echo ""
echo "--- file mode tests ---"
test_setup_local_prereqs_has_executable_mode
echo ""
echo "--- runbook alignment tests ---"; test_sla_baseline_runbook_matches_live_contract; echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
