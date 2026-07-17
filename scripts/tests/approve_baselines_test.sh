#!/usr/bin/env bash
# Focused tests for scripts/load/approve-baselines.sh profile defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

_json_field_from_file() {
    local json_path="$1" field="$2"
    python3 - "$json_path" "$field" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]

with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

value = payload
for part in field.split("."):
    value = value[part]

print(json.dumps(value))
PY
}

_write_mock_k6() {
    local mock_k6_path="$1"
    cat > "$mock_k6_path" <<'SH'
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
      "p(50)": 10,
      "p(95)": 20,
      "p(99)": 30
    },
    "http_reqs": {
      "count": 5000,
      "rate": 100
    },
    "http_req_failed": {
      "value": 0.0
    },
    "vus_max": {
      "value": 5
    }
  }
}
JSON
SH
    chmod +x "$mock_k6_path"
}

_run_approve_baselines() {
    local profile="$1"
    local baseline_dir="$2"
    local artifact_root="$3"
    local run_id="$4"
    local mock_bin="$5"
    local mock_k6_log="$6"
    local output exit_code=0
    local -a env_vars=(
        "PATH=$mock_bin:$PATH"
        "MOCK_K6_LOG=$mock_k6_log"
        "LOAD_BASELINE_DIR=$baseline_dir"
        "LOAD_APPROVAL_ARTIFACT_ROOT=$artifact_root"
        "LOAD_APPROVAL_RUN_ID=$run_id"
        "LOAD_APPROVAL_PROFILE="
        "LOAD_K6_MODE="
        "LOAD_K6_CONCURRENCY="
        "LOAD_K6_DURATION_SEC="
        "LOAD_APPROVAL_LOCAL_CONCURRENCY="
        "LOAD_APPROVAL_LOCAL_DURATION_SEC="
        "LOAD_PREPARE_LOCAL=0"
        "LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS=0"
        "JWT=test-jwt"
        "INDEX_NAME=test-index"
        "ADMIN_KEY=test-admin-key"
    )

    if [ -n "$profile" ]; then
        env_vars+=("LOAD_APPROVAL_PROFILE=$profile")
    fi

    output="$(env "${env_vars[@]}" bash "$REPO_ROOT/scripts/load/approve-baselines.sh" 2>/dev/null)" || exit_code=$?

    APPROVE_EXIT_CODE="$exit_code"
    APPROVE_OUTPUT="$output"
}

test_approve_baselines_defaults_to_local_fixed_profile() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    local artifact_root="$tmpdir/artifacts"
    local mock_bin="$tmpdir/mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    mkdir -p "$baseline_dir" "$artifact_root" "$mock_bin"
    _write_mock_k6 "$mock_bin/k6"

    _run_approve_baselines "" "$baseline_dir" "$artifact_root" "default-local-fixed" "$mock_bin" "$mock_k6_log"
    local exit_code="$APPROVE_EXIT_CODE"
    local log_contents baseline_count k6_mode
    log_contents="$(cat "$mock_k6_log")"
    baseline_count="$(ls "$baseline_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    k6_mode="$(_json_field_from_file "$baseline_dir/health.json" "meta.k6_mode")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "approve-baselines should succeed with default profile settings"
    assert_contains "$log_contents" "--vus 5" "default approval profile should force fixed-mode --vus"
    assert_contains "$log_contents" "--duration 45s" "default approval profile should force fixed-mode --duration"
    assert_eq "$baseline_count" "5" "approve-baselines should write one baseline per target endpoint"
    assert_eq "$k6_mode" "\"fixed\"" "default approval profile should persist meta.k6_mode as fixed"
}

test_approve_baselines_default_profile_ignores_inherited_profile_override() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    local artifact_root="$tmpdir/artifacts"
    local mock_bin="$tmpdir/mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    mkdir -p "$baseline_dir" "$artifact_root" "$mock_bin"
    _write_mock_k6 "$mock_bin/k6"

    LOAD_APPROVAL_PROFILE="staged" _run_approve_baselines "" "$baseline_dir" "$artifact_root" "default-ignores-inherited-profile" "$mock_bin" "$mock_k6_log"
    local exit_code="$APPROVE_EXIT_CODE"
    local log_contents k6_mode
    log_contents="$(cat "$mock_k6_log")"
    k6_mode="$(_json_field_from_file "$baseline_dir/health.json" "meta.k6_mode")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "approve-baselines should ignore inherited LOAD_APPROVAL_PROFILE in the default-profile test"
    assert_contains "$log_contents" "--vus 5" "default approval profile should still force fixed-mode --vus when parent shell exports LOAD_APPROVAL_PROFILE"
    assert_contains "$log_contents" "--duration 45s" "default approval profile should still force fixed-mode --duration when parent shell exports LOAD_APPROVAL_PROFILE"
    assert_eq "$k6_mode" "\"fixed\"" "default approval profile should still persist fixed mode when parent shell exports LOAD_APPROVAL_PROFILE"
}

test_approve_baselines_staged_profile_keeps_script_mode() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local baseline_dir="$tmpdir/baselines"
    local artifact_root="$tmpdir/artifacts"
    local mock_bin="$tmpdir/mock_bin"
    local mock_k6_log="$tmpdir/mock_k6.log"
    mkdir -p "$baseline_dir" "$artifact_root" "$mock_bin"
    _write_mock_k6 "$mock_bin/k6"

    _run_approve_baselines "staged" "$baseline_dir" "$artifact_root" "staged-profile" "$mock_bin" "$mock_k6_log"
    local exit_code="$APPROVE_EXIT_CODE"
    local log_contents baseline_count k6_mode
    log_contents="$(cat "$mock_k6_log")"
    baseline_count="$(ls "$baseline_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    k6_mode="$(_json_field_from_file "$baseline_dir/health.json" "meta.k6_mode")"

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "0" "approve-baselines should succeed for staged profile"
    if [[ "$log_contents" == *"--vus"* ]]; then
        fail "staged profile should not inject --vus fixed-mode flags"
    else
        pass "staged profile should omit --vus fixed-mode flags"
    fi
    if [[ "$log_contents" == *"--duration"* ]]; then
        fail "staged profile should not inject --duration fixed-mode flags"
    else
        pass "staged profile should omit --duration fixed-mode flags"
    fi
    assert_eq "$baseline_count" "5" "staged approval run should still write one baseline per target endpoint"
    assert_eq "$k6_mode" "\"script\"" "staged approval profile should persist meta.k6_mode as script"
}

echo "=== approve_baselines tests ==="
echo ""
test_approve_baselines_defaults_to_local_fixed_profile
test_approve_baselines_default_profile_ignores_inherited_profile_override
test_approve_baselines_staged_profile_keeps_script_mode
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
