#!/usr/bin/env bash
# Tests for scripts/local-signoff-cold-storage.sh: strict-env preflight,
# cargo test delegation, env mapping, and evidence emission.
# Uses mock cargo and curl — does NOT start real services.
#
# This test file is the single source of truth for the cold-storage signoff
# wrapper's external contract. Stage 2 implements the wrapper to satisfy
# these tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Minimal strict env for the cold-storage signoff wrapper.
# Only cold-storage-specific inputs — no commerce env vars.
strict_env_vars() {
    cat <<'EOF'
COLD_STORAGE_ENDPOINT=http://localhost:9000
COLD_STORAGE_BUCKET=fjcloud-cold-test
COLD_STORAGE_REGION=us-east-1
COLD_STORAGE_ACCESS_KEY=local-access
COLD_STORAGE_SECRET_KEY=local-secret
DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
EOF
}

TEST_TMP_DIR=""
TEST_CALL_LOG=""
CLEANUP_DIRS=()
RUN_OUTPUT=""
RUN_EXIT_CODE=0

cleanup_test_workspaces() {
    local tmp_dir
    for tmp_dir in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$tmp_dir"
    done
}

trap cleanup_test_workspaces EXIT

setup_test_workspace() {
    TEST_TMP_DIR=$(mktemp -d)
    CLEANUP_DIRS+=("$TEST_TMP_DIR")
    mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/artifacts"
    TEST_CALL_LOG="$TEST_TMP_DIR/calls.log"
    touch "$TEST_CALL_LOG"
}

shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

first_artifact_file() {
    local artifact_dir="$1" pattern="$2"
    local file
    for file in "$artifact_dir"/$pattern; do
        [ -e "$file" ] || continue
        printf '%s\n' "$file"
        return 0
    done
    return 1
}

artifact_dir() {
    printf '%s/artifacts/fjcloud-cold-storage-signoff\n' "$TEST_TMP_DIR"
}

call_log_contents() {
    cat "$TEST_CALL_LOG"
}

# Run the cold-storage signoff wrapper with given env overrides.
# Usage: run_signoff "$tmp_dir" [VAR=val ...]
run_signoff() {
    local tmp_dir="$1"; shift
    local env_args=()
    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(strict_env_vars)
    # Apply caller overrides (can override or unset vars)
    for arg in "$@"; do
        env_args+=("$arg")
    done
    # Mock-priority PATH: mock cargo/curl shadow real ones (first in PATH),
    # but system binaries (python3, mkdir, date) remain accessible for the
    # wrapper and validation_json.sh.
    env_args+=("PATH=$tmp_dir/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("TMPDIR=$tmp_dir/artifacts")

    env -i "${env_args[@]}" \
        /bin/bash "$REPO_ROOT/scripts/local-signoff-cold-storage.sh" 2>&1 || return $?
}

run_signoff_capture() {
    local tmp_dir="$1"
    shift

    RUN_EXIT_CODE=0
    RUN_OUTPUT=$(run_signoff "$tmp_dir" "$@") || RUN_EXIT_CODE=$?
}

# Write a mock cargo that records the full command line and key env vars
# to a call log, then exits 0.
write_mock_cargo() {
    local path="$1" call_log="$2"
    local quoted_call_log
    # Escape the redirection target before embedding it into generated shell so
    # TMPDIR-derived paths cannot trigger command substitution at mock runtime.
    quoted_call_log=$(shell_quote_for_script "$call_log")
cat > "$path" <<MOCK
#!/bin/bash
# Record the full command line
echo "cargo \$*" >> $quoted_call_log
# Record key env vars used by the cold-storage integration test
{
    echo "ENV:INTEGRATION=\${INTEGRATION:-}"
    echo "ENV:BACKEND_LIVE_GATE=\${BACKEND_LIVE_GATE:-}"
    echo "ENV:INTEGRATION_API_BASE=\${INTEGRATION_API_BASE:-}"
    echo "ENV:INTEGRATION_FLAPJACK_BASE=\${INTEGRATION_FLAPJACK_BASE:-}"
    echo "ENV:INTEGRATION_DB_URL=\${INTEGRATION_DB_URL:-}"
    echo "ENV:COLD_STORAGE_ENDPOINT=\${COLD_STORAGE_ENDPOINT:-}"
    echo "ENV:COLD_STORAGE_BUCKET=\${COLD_STORAGE_BUCKET:-}"
    echo "ENV:COLD_STORAGE_REGION=\${COLD_STORAGE_REGION:-}"
    echo "ENV:COLD_STORAGE_ACCESS_KEY=\${COLD_STORAGE_ACCESS_KEY:-}"
    echo "ENV:COLD_STORAGE_SECRET_KEY=\${COLD_STORAGE_SECRET_KEY:-}"
    echo "ENV:PWD=\${PWD:-}"
    echo "ENV:PATH=\${PATH:-}"
} >> $quoted_call_log
exit 0
MOCK
    chmod +x "$path"
}

# Write a mock curl that responds to /health and logs all calls.
write_health_mock_curl() {
    local path="$1" call_log="$2"
    local quoted_call_log
    quoted_call_log=$(shell_quote_for_script "$call_log")
cat > "$path" <<MOCK
#!/bin/bash
echo "curl \$*" >> $quoted_call_log
for arg in "\$@"; do
    if [[ "\$arg" == */health ]]; then
        echo '{"status":"ok"}'
        exit 0
    fi
done
echo '{"status":"ok"}'
exit 0
MOCK
    chmod +x "$path"
}

# Write a mock curl that fails /health (simulates endpoint down).
write_failing_health_mock_curl() {
    local path="$1" call_log="$2"
    local quoted_call_log
    quoted_call_log=$(shell_quote_for_script "$call_log")
cat > "$path" <<MOCK
#!/bin/bash
echo "curl \$*" >> $quoted_call_log
for arg in "\$@"; do
    if [[ "\$arg" == */health ]]; then
        exit 1
    fi
done
exit 1
MOCK
    chmod +x "$path"
}

# Setup a full test workspace with both mock cargo and healthy mock curl.
setup_full_test_workspace() {
    local curl_writer="${1:-write_health_mock_curl}"
    setup_test_workspace
    write_mock_cargo "$TEST_TMP_DIR/bin/cargo" "$TEST_CALL_LOG"
    "$curl_writer" "$TEST_TMP_DIR/bin/curl" "$TEST_CALL_LOG"
}

assert_missing_required_env() {
    local env_name="$1"

    setup_full_test_workspace
    run_signoff_capture "$TEST_TMP_DIR" "$env_name="

    assert_eq "$RUN_EXIT_CODE" "1" "should fail when $env_name is unset"
    assert_contains "$RUN_OUTPUT" "$env_name" \
        "should name the missing $env_name in the error"
}

# ============================================================================
# Preflight Tests
# ============================================================================

test_rejects_missing_cold_storage_endpoint() {
    assert_missing_required_env "COLD_STORAGE_ENDPOINT"
}

test_rejects_missing_cold_storage_bucket() {
    assert_missing_required_env "COLD_STORAGE_BUCKET"
}

test_rejects_missing_cold_storage_region() {
    assert_missing_required_env "COLD_STORAGE_REGION"
}

test_rejects_missing_cold_storage_access_key() {
    assert_missing_required_env "COLD_STORAGE_ACCESS_KEY"
}

test_rejects_missing_cold_storage_secret_key() {
    assert_missing_required_env "COLD_STORAGE_SECRET_KEY"
}

test_rejects_missing_both_db_urls() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR" "DATABASE_URL=" "INTEGRATION_DB_URL="

    assert_eq "$RUN_EXIT_CODE" "1" "should fail when both DATABASE_URL and INTEGRATION_DB_URL are unset"
    assert_contains "$RUN_OUTPUT" "INTEGRATION_DB_URL" \
        "should mention INTEGRATION_DB_URL in the actionable error"
    assert_contains "$RUN_OUTPUT" "DATABASE_URL" \
        "should mention DATABASE_URL in the actionable error"
}

test_rejects_unhealthy_api_endpoint() {
    setup_full_test_workspace write_failing_health_mock_curl

    run_signoff_capture "$TEST_TMP_DIR"

    assert_eq "$RUN_EXIT_CODE" "1" "should fail when API health check fails"
    assert_contains "$RUN_OUTPUT" "health" \
        "should mention health check failure"
}

# ============================================================================
# Delegation Tests — cargo test command and env vars
# ============================================================================

test_delegates_exact_cargo_test_command() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    assert_eq "$RUN_EXIT_CODE" "0" "should succeed with all required env vars"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" \
        "cargo test -p api --test integration_cold_tier_test cold_tier_full_lifecycle_s3_round_trip -- --test-threads=1" \
        "should delegate the exact cargo test command for cold-tier lifecycle"
    assert_contains "$calls" "ENV:PWD=$REPO_ROOT/infra" \
        "should run the delegated cargo command from the infra workspace"
}

test_exports_integration_and_live_gate() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION=1" \
        "should export INTEGRATION=1"
    assert_contains "$calls" "ENV:BACKEND_LIVE_GATE=1" \
        "should export BACKEND_LIVE_GATE=1"
}

test_derives_integration_db_url_from_database_url() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR" \
        "DATABASE_URL=postgres://user:pass@host:5432/mydb" \
        "INTEGRATION_DB_URL="

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION_DB_URL=postgres://user:pass@host:5432/mydb" \
        "should derive INTEGRATION_DB_URL from DATABASE_URL when not explicitly set"
}

test_preserves_explicit_integration_db_url() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR" \
        "DATABASE_URL=postgres://fallback:pass@host:5432/fallbackdb" \
        "INTEGRATION_DB_URL=postgres://explicit:pass@host:5432/explicitdb"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION_DB_URL=postgres://explicit:pass@host:5432/explicitdb" \
        "should preserve explicit INTEGRATION_DB_URL over DATABASE_URL"
}

test_sets_strict_local_api_base() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION_API_BASE=http://localhost:3001" \
        "should set INTEGRATION_API_BASE to the strict-local stack URL (overriding Rust default of localhost:3099)"
}

test_sets_strict_local_flapjack_base() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION_FLAPJACK_BASE=http://127.0.0.1:7700" \
        "should set INTEGRATION_FLAPJACK_BASE to the strict-local stack URL (overriding Rust default of localhost:7799)"
}

test_preserves_explicit_api_base_override() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR" \
        "INTEGRATION_API_BASE=http://custom-api:4000"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION_API_BASE=http://custom-api:4000" \
        "should preserve explicit INTEGRATION_API_BASE override"
}

test_preserves_explicit_flapjack_base_override() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR" \
        "INTEGRATION_FLAPJACK_BASE=http://custom-flapjack:8800"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:INTEGRATION_FLAPJACK_BASE=http://custom-flapjack:8800" \
        "should preserve explicit INTEGRATION_FLAPJACK_BASE override"
}

test_passes_cold_storage_vars_to_cargo() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR" \
        "COLD_STORAGE_ENDPOINT=http://minio:9000" \
        "COLD_STORAGE_BUCKET=test-bucket" \
        "COLD_STORAGE_REGION=eu-west-1" \
        "COLD_STORAGE_ACCESS_KEY=test-access" \
        "COLD_STORAGE_SECRET_KEY=test-secret"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:COLD_STORAGE_ENDPOINT=http://minio:9000" \
        "should pass COLD_STORAGE_ENDPOINT through to cargo env"
    assert_contains "$calls" "ENV:COLD_STORAGE_BUCKET=test-bucket" \
        "should pass COLD_STORAGE_BUCKET through to cargo env"
    assert_contains "$calls" "ENV:COLD_STORAGE_REGION=eu-west-1" \
        "should pass COLD_STORAGE_REGION through to cargo env"
    assert_contains "$calls" "ENV:COLD_STORAGE_ACCESS_KEY=test-access" \
        "should pass COLD_STORAGE_ACCESS_KEY through to cargo env"
    assert_contains "$calls" "ENV:COLD_STORAGE_SECRET_KEY=test-secret" \
        "should pass COLD_STORAGE_SECRET_KEY through to cargo env"
}

test_uses_mock_priority_path() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    local calls
    calls=$(call_log_contents)
    assert_contains "$calls" "ENV:PATH=$TEST_TMP_DIR/bin" \
        "should run wrapper with mock bin dir first on PATH (mock cargo/curl shadow real)"
}

# ============================================================================
# Evidence Emission Tests
# ============================================================================

test_creates_artifact_dir_outside_repo() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    # Artifact dir should be created under TMPDIR, not in the repo
    local signoff_artifact_dir
    signoff_artifact_dir=$(artifact_dir)
    if [ -d "$signoff_artifact_dir" ]; then
        pass "should create artifact directory under TMPDIR"
    else
        fail "should create artifact directory under TMPDIR (not found at $signoff_artifact_dir)"
    fi
}

test_emits_json_evidence_file() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    local signoff_artifact_dir
    signoff_artifact_dir=$(artifact_dir)
    local json_file
    json_file=$(first_artifact_file "$signoff_artifact_dir" "*.json" 2>/dev/null || true)
    if [ -n "$json_file" ]; then
        pass "should write JSON evidence file"
        local json_content
        json_content=$(cat "$json_file")
        assert_valid_json "$json_content" "JSON evidence should be valid JSON"
        assert_contains "$json_content" '"passed":true' \
            "JSON evidence should report passed=true"
        assert_contains "$json_content" '"steps"' \
            "JSON evidence should contain steps array"
    else
        fail "should write JSON evidence file (no .json found in $signoff_artifact_dir)"
    fi
}

test_emits_operator_summary_file() {
    setup_full_test_workspace

    run_signoff_capture "$TEST_TMP_DIR"

    local signoff_artifact_dir
    signoff_artifact_dir=$(artifact_dir)
    local txt_file
    txt_file=$(first_artifact_file "$signoff_artifact_dir" "*.txt" 2>/dev/null || true)
    if [ -n "$txt_file" ]; then
        pass "should write operator summary file"
        local txt_content
        txt_content=$(cat "$txt_file")
        assert_contains "$txt_content" "PASSED" \
            "operator summary should report PASSED"
    else
        fail "should write operator summary file (no .txt found in $signoff_artifact_dir)"
    fi
}

test_preserves_failing_cargo_exit_code() {
    setup_test_workspace
    local quoted_call_log
    quoted_call_log=$(shell_quote_for_script "$TEST_CALL_LOG")
    cat > "$TEST_TMP_DIR/bin/cargo" <<MOCK
#!/bin/bash
echo "cargo \$*" >> $quoted_call_log
echo "mock cargo failed" >&2
exit 23
MOCK
    chmod +x "$TEST_TMP_DIR/bin/cargo"
    write_health_mock_curl "$TEST_TMP_DIR/bin/curl" "$TEST_CALL_LOG"

    run_signoff_capture "$TEST_TMP_DIR"

    assert_eq "$RUN_EXIT_CODE" "23" "should preserve the delegated cargo exit code"
    assert_contains "$RUN_OUTPUT" "mock cargo failed" \
        "should surface delegated cargo stderr"
}

test_generated_mocks_escape_call_log_path() {
    setup_test_workspace

    local marker_name="command-substitution-ran"
    local marker_file="$TEST_TMP_DIR/$marker_name"
    local injected_call_log="${TEST_TMP_DIR}/calls\$(touch ${marker_name}).log"

    write_mock_cargo "$TEST_TMP_DIR/bin/cargo" "$injected_call_log"
    (
        cd "$TEST_TMP_DIR"
        "$TEST_TMP_DIR/bin/cargo" smoke-test >/dev/null 2>&1
    )

    if [ -e "$marker_file" ]; then
        fail "generated mock should not execute command substitutions from the call log path"
    else
        pass "generated mock should not execute command substitutions from the call log path"
    fi

    if [ -f "$injected_call_log" ]; then
        pass "generated mock should write to the literal call log path"
    else
        fail "generated mock should write to the literal call log path"
    fi
}

# ============================================================================
# Run Tests
# ============================================================================

echo "=== local-signoff-cold-storage.sh tests ==="
echo ""
echo "--- Preflight ---"
test_rejects_missing_cold_storage_endpoint
test_rejects_missing_cold_storage_bucket
test_rejects_missing_cold_storage_region
test_rejects_missing_cold_storage_access_key
test_rejects_missing_cold_storage_secret_key
test_rejects_missing_both_db_urls
test_rejects_unhealthy_api_endpoint

echo ""
echo "--- Delegation & Env Mapping ---"
test_delegates_exact_cargo_test_command
test_exports_integration_and_live_gate
test_derives_integration_db_url_from_database_url
test_preserves_explicit_integration_db_url
test_sets_strict_local_api_base
test_sets_strict_local_flapjack_base
test_preserves_explicit_api_base_override
test_preserves_explicit_flapjack_base_override
test_passes_cold_storage_vars_to_cargo
test_uses_mock_priority_path

echo ""
echo "--- Evidence Emission ---"
test_creates_artifact_dir_outside_repo
test_emits_json_evidence_file
test_emits_operator_summary_file
test_preserves_failing_cargo_exit_code
test_generated_mocks_escape_call_log_path

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ] || exit 1
