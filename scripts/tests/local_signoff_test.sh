#!/usr/bin/env bash
# Tests for scripts/local-signoff.sh — top-level orchestrator that delegates
# to commerce, cold-storage, and HA proof-owner scripts.
#
# Red-first: all tests fail until Stage 2 implements the orchestrator.
# Uses mock proof scripts in a temp workspace — does NOT invoke real proofs.
# Follows the mock-binary + controlled PATH pattern from
# local_signoff_cold_storage_test.sh and chaos_test.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------
CLEANUP_DIRS=()
TEST_WORKSPACE=""
TEST_CALL_LOG=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0
cleanup_test_workspaces() {
    local d
    for d in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup_test_workspaces EXIT
# Single canonical valid env fixture for all orchestrator tests.
# Union of env vars required by commerce, cold-storage, and HA.
baseline_orchestrator_env() {
    cat <<'EOF'
STRIPE_LOCAL_MODE=1
MAILPIT_API_URL=http://localhost:8025
STRIPE_WEBHOOK_SECRET=whsec_test_signoff
COLD_STORAGE_ENDPOINT=http://localhost:9000
COLD_STORAGE_BUCKET=fjcloud-cold-test
COLD_STORAGE_REGION=us-east-1
COLD_STORAGE_ACCESS_KEY=local-access
COLD_STORAGE_SECRET_KEY=local-secret
FLAPJACK_REGIONS=us-east-1:7700
DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev
EOF
}
write_baseline_orchestrator_env_file() {
    baseline_orchestrator_env > "$1"
}
shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}
setup_orchestrator_workspace() {
    local workspace_root
    workspace_root=$(mktemp -d)
    CLEANUP_DIRS+=("$workspace_root")
    TEST_WORKSPACE="$workspace_root/workspace"
    mkdir -p "$TEST_WORKSPACE/scripts/chaos" \
             "$TEST_WORKSPACE/scripts/lib" \
             "$TEST_WORKSPACE/bin" \
             "$TEST_WORKSPACE/artifacts"
    TEST_CALL_LOG="$TEST_WORKSPACE/calls.log"
    touch "$TEST_CALL_LOG"
    # Copy shared libs the orchestrator may source.
    local lib
    for lib in env.sh validation_json.sh flapjack_binary.sh flapjack_regions.sh; do
        [ -f "$REPO_ROOT/scripts/lib/$lib" ] && \
            cp "$REPO_ROOT/scripts/lib/$lib" "$TEST_WORKSPACE/scripts/lib/"
    done
    # Copy orchestrator (absent in red phase — tests fail as expected).
    [ -f "$REPO_ROOT/scripts/local-signoff.sh" ] && \
        cp "$REPO_ROOT/scripts/local-signoff.sh" "$TEST_WORKSPACE/scripts/" || true
    write_mock_curl 0
}
# Create a mock proof-owner script that logs invocation and exits with
# the given code. Log format: "name|args" per line.
write_mock_proof_script() {
    local name="$1" exit_code="${2:-0}"
    local script_path
    case "$name" in
        commerce)     script_path="$TEST_WORKSPACE/scripts/local-signoff-commerce.sh" ;;
        cold-storage) script_path="$TEST_WORKSPACE/scripts/local-signoff-cold-storage.sh" ;;
        ha)           script_path="$TEST_WORKSPACE/scripts/chaos/ha-failover-proof.sh" ;;
        *) echo "Unknown proof: $name" >&2; return 1 ;;
    esac
    local quoted_log
    quoted_log=$(shell_quote_for_script "$TEST_CALL_LOG")
    cat > "$script_path" <<MOCK
#!/usr/bin/env bash
echo "$name|\$*" >> $quoted_log
exit $exit_code
MOCK
    chmod +x "$script_path"
}
write_mock_seed_script() {
    local exit_code="${1:-0}"
    local quoted_log
    quoted_log=$(shell_quote_for_script "$TEST_CALL_LOG")
    cat > "$TEST_WORKSPACE/scripts/seed_local.sh" <<MOCK
#!/usr/bin/env bash
echo "seed|\$*" >> $quoted_log
exit $exit_code
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/seed_local.sh"
}
write_mock_curl() {
    local exit_code="${1:-0}"
    local quoted_log
    quoted_log=$(shell_quote_for_script "$TEST_CALL_LOG")
    cat > "$TEST_WORKSPACE/bin/curl" <<MOCK
#!/usr/bin/env bash
echo "curl|\$*" >> $quoted_log
exit $exit_code
MOCK
    chmod +x "$TEST_WORKSPACE/bin/curl"
}
install_passing_mocks() {
    write_mock_proof_script commerce 0
    write_mock_proof_script cold-storage 0
    write_mock_proof_script ha 0
}
install_prereq_command_mocks() {
    local cmd
    for cmd in docker curl jq; do
        write_mock_script "$TEST_WORKSPACE/bin/$cmd" 'exit 0'
    done
}
install_minimal_path_utils() {
    write_mock_script "$TEST_WORKSPACE/bin/dirname" '
path="${1:-.}"
if [[ "$path" == */* ]]; then
    echo "${path%/*}"
else
    echo "."
fi
'
    write_mock_script "$TEST_WORKSPACE/bin/python3" '
if [ "${1:-}" = "-c" ]; then
    echo 0
fi
exit 0
'
}
install_path_flapjack_binary() {
    write_mock_script "$TEST_WORKSPACE/bin/flapjack" 'exit 0'
}
create_flapjack_binary_under() {
    local root_dir="$1"
    local binary_path="$root_dir/target/debug/flapjack"
    mkdir -p "$(dirname "$binary_path")"
    write_mock_script "$binary_path" 'exit 0'
}
proof_call_count() {
    local count
    count=$(grep -c "^${1}|" "$TEST_CALL_LOG" 2>/dev/null) || true
    echo "${count:-0}"
}
call_log_line_count() {
    wc -l < "$TEST_CALL_LOG" | tr -d ' '
}
# Run the orchestrator with baseline env + optional overrides and CLI args.
# Usage: run_orchestrator [--args "arg1 arg2"] [VAR=val ...]
run_orchestrator() {
    local extra_args=""
    local path_override=""
    # Build baseline env.
    local env_args=()
    while IFS= read -r line; do
        [ -n "$line" ] && env_args+=("$line")
    done < <(baseline_orchestrator_env)
    # Process arguments: --args for CLI flags, everything else as env overrides.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args) extra_args="$2"; shift 2 ;;
            PATH=*) path_override="${1#PATH=}"; shift ;;
            *)      env_args+=("$1"); shift ;;
        esac
    done
    if [ -n "$path_override" ]; then
        env_args+=("PATH=$path_override")
    else
        # Keep PATH deterministic for flapjack-binary resolution tests.
        env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin")
    fi
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/artifacts")
    local orchestrator="$TEST_WORKSPACE/scripts/local-signoff.sh"
    RUN_EXIT_CODE=0
    if [ -n "$extra_args" ]; then
        # shellcheck disable=SC2086
        RUN_OUTPUT=$(env -i "${env_args[@]}" /bin/bash "$orchestrator" $extra_args 2>&1) || RUN_EXIT_CODE=$?
    else
        RUN_OUTPUT=$(env -i "${env_args[@]}" /bin/bash "$orchestrator" 2>&1) || RUN_EXIT_CODE=$?
    fi
}
# Find the orchestrator's artifact dir under TMPDIR.
find_artifact_dir() {
    local d
    for d in "$TEST_WORKSPACE/artifacts/fjcloud-local-signoff-"*; do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}
# ============================================================================
# Env Preflight Tests
# ============================================================================
test_preflight_missing_stripe_local_mode() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator "STRIPE_LOCAL_MODE="
    assert_eq "$RUN_EXIT_CODE" "1" "missing STRIPE_LOCAL_MODE → exit 1"
    assert_contains "$RUN_OUTPUT" "STRIPE_LOCAL_MODE" "error names STRIPE_LOCAL_MODE"
}
test_preflight_missing_cold_storage_endpoint() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator "COLD_STORAGE_ENDPOINT="
    assert_eq "$RUN_EXIT_CODE" "1" "missing COLD_STORAGE_ENDPOINT → exit 1"
    assert_contains "$RUN_OUTPUT" "COLD_STORAGE_ENDPOINT" "error names COLD_STORAGE_ENDPOINT"
}
test_preflight_missing_flapjack_regions() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator "FLAPJACK_REGIONS="
    assert_eq "$RUN_EXIT_CODE" "1" "missing FLAPJACK_REGIONS → exit 1"
    assert_contains "$RUN_OUTPUT" "FLAPJACK_REGIONS" "error names FLAPJACK_REGIONS"
}
test_preflight_skip_email_verification_set() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator "SKIP_EMAIL_VERIFICATION=1"
    assert_eq "$RUN_EXIT_CODE" "1" "SKIP_EMAIL_VERIFICATION set → exit 1"
    assert_contains "$RUN_OUTPUT" "SKIP_EMAIL_VERIFICATION" "error names SKIP_EMAIL_VERIFICATION"
}
# ============================================================================
# --check-prerequisites Tests (Stage 2)
# ============================================================================
test_check_prerequisites_exits_before_delegation_and_artifacts() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 0
    install_prereq_command_mocks
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites"
    assert_eq "$RUN_EXIT_CODE" "0" "--check-prerequisites should pass with mocked prerequisites"
    assert_eq "$(proof_call_count commerce)" "0" "check-prerequisites should not invoke commerce proof"
    assert_eq "$(proof_call_count cold-storage)" "0" "check-prerequisites should not invoke cold-storage proof"
    assert_eq "$(proof_call_count ha)" "0" "check-prerequisites should not invoke HA proof"
    assert_eq "$(grep -c '^seed|' "$TEST_CALL_LOG" 2>/dev/null || true)" "0" \
        "check-prerequisites should not refresh seed state"
    assert_contains "$RUN_OUTPUT" "prerequisite ok:" \
        "check-prerequisites should print prerequisite-ok lines"
    if find_artifact_dir >/dev/null 2>&1; then
        fail "check-prerequisites should not create artifact directory"
    else
        pass "check-prerequisites does not create artifact directory"
    fi
}
test_check_prerequisites_loads_repo_env_file() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 0
    install_prereq_command_mocks
    local env_file="$TEST_WORKSPACE/.env.local"
    local flapjack_dir="$TEST_WORKSPACE/from_env_file"
    write_baseline_orchestrator_env_file "$env_file"
    mkdir -p "$flapjack_dir/target/debug"
    write_mock_script "$flapjack_dir/target/debug/flapjack" 'exit 0'
    cat >> "$env_file" <<EOF
FLAPJACK_DEV_DIR=$flapjack_dir
EOF

    RUN_EXIT_CODE=0
    RUN_OUTPUT=$(
        env -i \
            PATH="$TEST_WORKSPACE/bin:/usr/bin:/bin" \
            HOME="$TEST_WORKSPACE" \
            TMPDIR="$TEST_WORKSPACE/artifacts" \
            /bin/bash "$TEST_WORKSPACE/scripts/local-signoff.sh" --check-prerequisites 2>&1
    ) || RUN_EXIT_CODE=$?

    assert_eq "$RUN_EXIT_CODE" "0" \
        "check-prerequisites should load strict signoff inputs from repo .env.local"
    assert_contains "$RUN_OUTPUT" "All prerequisites satisfied" \
        "check-prerequisites should pass when .env.local supplies the strict env contract"
    assert_eq "$(proof_call_count commerce)" "0" \
        "file-backed check-prerequisites should still exit before proof delegation"
}
test_check_prerequisites_reports_missing_docker() {
    setup_orchestrator_workspace; install_passing_mocks
    install_minimal_path_utils
    write_mock_script "$TEST_WORKSPACE/bin/curl" 'exit 0'
    write_mock_script "$TEST_WORKSPACE/bin/jq" 'exit 0'
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" "PATH=$TEST_WORKSPACE/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "1" "missing docker should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: missing:docker" \
        "check-prerequisites should report docker by name + reason code"
    assert_contains "$RUN_OUTPUT" "REASON: prerequisite_missing" \
        "check-prerequisites failure should emit prerequisite reason code"
    assert_eq "$(proof_call_count ha)" "0" "failed check-prerequisites should not delegate to HA proof"
}
test_check_prerequisites_reports_missing_curl() {
    setup_orchestrator_workspace; install_passing_mocks
    install_minimal_path_utils
    rm -f "$TEST_WORKSPACE/bin/curl"
    write_mock_script "$TEST_WORKSPACE/bin/docker" 'exit 0'
    write_mock_script "$TEST_WORKSPACE/bin/jq" 'exit 0'
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" "PATH=$TEST_WORKSPACE/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "1" "missing curl should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: missing:curl" \
        "check-prerequisites should report curl by name + reason code"
}
test_check_prerequisites_reports_missing_jq() {
    setup_orchestrator_workspace; install_passing_mocks
    install_minimal_path_utils
    write_mock_script "$TEST_WORKSPACE/bin/docker" 'exit 0'
    write_mock_script "$TEST_WORKSPACE/bin/curl" 'exit 0'
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" "PATH=$TEST_WORKSPACE/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "1" "missing jq should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: missing:jq" \
        "check-prerequisites should report jq by name + reason code"
}
test_check_prerequisites_reports_malformed_flapjack_regions() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" "FLAPJACK_REGIONS=us-east-1"
    assert_eq "$RUN_EXIT_CODE" "1" "malformed FLAPJACK_REGIONS should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: malformed:FLAPJACK_REGIONS" \
        "check-prerequisites should report malformed FLAPJACK_REGIONS"
}
test_check_prerequisites_rejects_duplicate_flapjack_regions() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_REGIONS=us-east-1:7700 us-east-1:8800"
    assert_eq "$RUN_EXIT_CODE" "1" "duplicate FLAPJACK_REGIONS entries should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: malformed:FLAPJACK_REGIONS" \
        "check-prerequisites should reject duplicate-region topology"
}
test_check_prerequisites_reports_malformed_database_url() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" "DATABASE_URL=not-a-url"
    assert_eq "$RUN_EXIT_CODE" "1" "malformed DATABASE_URL should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: malformed:DATABASE_URL" \
        "check-prerequisites should report malformed DATABASE_URL"
}
test_check_prerequisites_does_not_leak_secret_values() {
    local flapjack_admin_key="test-flapjack-admin-secret-1234"
    local admin_key="test-admin-secret-5678"
    local cold_storage_access_key="test-cold-storage-access-9999"
    local cold_storage_secret_key="test-cold-storage-secret-0000"
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_REGIONS=us-east-1" \
        "FLAPJACK_ADMIN_KEY=$flapjack_admin_key" \
        "ADMIN_KEY=$admin_key" \
        "COLD_STORAGE_ACCESS_KEY=$cold_storage_access_key" \
        "COLD_STORAGE_SECRET_KEY=$cold_storage_secret_key"
    assert_eq "$RUN_EXIT_CODE" "1" "malformed FLAPJACK_REGIONS should fail check-prerequisites"
    assert_not_contains "$RUN_OUTPUT" "$flapjack_admin_key" \
        "output should not leak FLAPJACK_ADMIN_KEY full value"
    assert_not_contains "$RUN_OUTPUT" "$admin_key" \
        "output should not leak ADMIN_KEY full value"
    assert_not_contains "$RUN_OUTPUT" "$cold_storage_access_key" \
        "output should not leak COLD_STORAGE_ACCESS_KEY full value"
    assert_not_contains "$RUN_OUTPUT" "$cold_storage_secret_key" \
        "output should not leak COLD_STORAGE_SECRET_KEY full value"
}
test_check_prerequisites_accepts_explicit_flapjack_dev_dir_binary() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    local explicit_dir="$TEST_WORKSPACE/explicit_flapjack/engine"
    create_flapjack_binary_under "$explicit_dir"
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_DEV_DIR=$explicit_dir" \
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "0" "explicit FLAPJACK_DEV_DIR binary should satisfy check-prerequisites"
    assert_contains "$RUN_OUTPUT" "prerequisite ok: flapjack_binary" \
        "check-prerequisites should report flapjack binary success"
}
test_check_prerequisites_accepts_later_candidate_binary_after_empty_dirs() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    local explicit_dir="$TEST_WORKSPACE/explicit_flapjack"
    local first_candidate="$TEST_WORKSPACE/empty_candidate"
    local second_candidate="$TEST_WORKSPACE/second_candidate/engine"
    local candidate_list="$first_candidate $second_candidate"
    mkdir -p "$explicit_dir" "$first_candidate"
    create_flapjack_binary_under "$second_candidate"
    rm -f "$TEST_WORKSPACE/bin/flapjack" "$TEST_WORKSPACE/bin/flapjack-http"
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_DEV_DIR=$explicit_dir" \
        "FLAPJACK_DEV_DIR_CANDIDATES=$candidate_list" \
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "0" "later candidate flapjack binary should satisfy check-prerequisites after empty dirs"
    assert_contains "$RUN_OUTPUT" "prerequisite ok: flapjack_binary" \
        "check-prerequisites should continue past empty explicit/candidate dirs until a binary resolves"
}
test_check_prerequisites_accepts_default_repo_candidates_binary() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    local default_candidate="$TEST_WORKSPACE/../flapjack_dev/engine"
    create_flapjack_binary_under "$default_candidate"
    rm -f "$TEST_WORKSPACE/bin/flapjack" "$TEST_WORKSPACE/bin/flapjack-http"
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_DEV_DIR=" \
        "FLAPJACK_DEV_DIR_CANDIDATES=" \
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "0" "default repo candidate flapjack binary should satisfy check-prerequisites"
}
test_check_prerequisites_accepts_path_flapjack_binary() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    install_path_flapjack_binary
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_DEV_DIR=/nonexistent" \
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "0" "PATH flapjack binary should satisfy check-prerequisites"
}
test_check_prerequisites_fails_closed_without_flapjack_binary() {
    setup_orchestrator_workspace; install_passing_mocks
    install_prereq_command_mocks
    rm -f "$TEST_WORKSPACE/bin/flapjack" "$TEST_WORKSPACE/bin/flapjack-http"
    run_orchestrator --args "--check-prerequisites" \
        "FLAPJACK_DEV_DIR=/nonexistent" \
        "FLAPJACK_DEV_DIR_CANDIDATES=" \
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin"
    assert_eq "$RUN_EXIT_CODE" "1" "missing flapjack binary should fail check-prerequisites"
    assert_contains "$RUN_OUTPUT" "ERROR: missing:flapjack_binary" \
        "check-prerequisites should fail-closed when no flapjack binary resolves"
    assert_contains "$RUN_OUTPUT" "REASON: prerequisite_missing" \
        "missing flapjack binary should emit prerequisite_missing reason code"
    assert_eq "$(proof_call_count ha)" "0" \
        "missing flapjack binary in check-prerequisites must fail before HA delegation"
}
# ============================================================================
# Delegation Ordering Tests
# ============================================================================
test_delegation_all_pass_exit_zero() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    assert_eq "$RUN_EXIT_CODE" "0" "all proofs pass → exit 0"
}
test_delegation_order() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    local commerce_line cold_storage_line ha_line
    commerce_line=$(grep -n "^commerce|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    cold_storage_line=$(grep -n "^cold-storage|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    ha_line=$(grep -n "^ha|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -n "$commerce_line" ] && [ -n "$cold_storage_line" ] && [ -n "$ha_line" ] \
       && [ "$commerce_line" -lt "$cold_storage_line" ] \
       && [ "$cold_storage_line" -lt "$ha_line" ]; then
        pass "delegation order: commerce → cold-storage → HA"
    else
        fail "delegation order: commerce → cold-storage → HA (lines: c=${commerce_line:-?} cs=${cold_storage_line:-?} ha=${ha_line:-?})"
    fi
}
test_delegation_each_called_once() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    assert_eq "$(proof_call_count commerce)" "1" "commerce called exactly once"
    assert_eq "$(proof_call_count cold-storage)" "1" "cold-storage called exactly once"
    assert_eq "$(proof_call_count ha)" "1" "HA called exactly once"
}
test_delegation_commerce_no_args() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    local entry
    entry=$(grep "^commerce|" "$TEST_CALL_LOG" 2>/dev/null | head -1 || true)
    assert_eq "$entry" "commerce|" "commerce receives no arguments"
}
test_delegation_cold_storage_no_args() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    local entry
    entry=$(grep "^cold-storage|" "$TEST_CALL_LOG" 2>/dev/null | head -1 || true)
    assert_eq "$entry" "cold-storage|" "cold-storage receives no arguments"
}
test_delegation_ha_receives_region() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator "FLAPJACK_REGIONS=us-east-1:7700"
    local entry
    entry=$(grep "^ha|" "$TEST_CALL_LOG" 2>/dev/null | head -1 || true)
    assert_contains "$entry" "us-east-1" "HA receives region from FLAPJACK_REGIONS"
}
test_delegation_refreshes_seed_immediately_before_ha() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 0
    run_orchestrator
    local cold_storage_line seed_line ha_line
    cold_storage_line=$(grep -n "^cold-storage|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    seed_line=$(grep -n "^seed|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    ha_line=$(grep -n "^ha|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -n "$cold_storage_line" ] && [ -n "$seed_line" ] && [ -n "$ha_line" ] \
       && [ "$cold_storage_line" -lt "$seed_line" ] \
       && [ "$seed_line" -lt "$ha_line" ]; then
        pass "delegation order: cold-storage → seed refresh → HA"
    else
        fail "delegation order: cold-storage → seed refresh → HA (lines: cs=${cold_storage_line:-?} seed=${seed_line:-?} ha=${ha_line:-?})"
    fi
}
test_delegation_seed_refresh_failure_stops_ha() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 1
    run_orchestrator
    assert_eq "$RUN_EXIT_CODE" "1" "seed refresh failure → non-zero exit"
    assert_eq "$(proof_call_count ha)" "0" "HA not called after seed refresh failure"
    assert_eq "$(grep -c '^seed|' "$TEST_CALL_LOG" 2>/dev/null || true)" "1" \
        "seed refresh called exactly once before failing HA"
}
test_post_ha_health_runs_after_full_ha_success() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 0
    run_orchestrator
    local ha_line api_health_line region_health_line
    ha_line=$(grep -n "^ha|" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    api_health_line=$(grep -n "^curl|.*http://localhost:3001/health" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    region_health_line=$(grep -n "^curl|.*http://127.0.0.1:7700/health" "$TEST_CALL_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [ -n "$ha_line" ] && [ -n "$api_health_line" ] && [ -n "$region_health_line" ] \
       && [ "$ha_line" -lt "$api_health_line" ] \
       && [ "$ha_line" -lt "$region_health_line" ]; then
        pass "post-HA health checks run after HA proof succeeds"
    else
        fail "post-HA health checks should run after HA proof (ha=${ha_line:-?} api=${api_health_line:-?} region=${region_health_line:-?})"
    fi
}
test_post_ha_health_failure_fails_signoff() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 0
    write_mock_curl 1
    run_orchestrator
    assert_eq "$RUN_EXIT_CODE" "1" "post-HA health failure → non-zero exit"
    assert_contains "$RUN_OUTPUT" "post-HA health" \
        "post-HA health failure should be surfaced in the orchestrator output"
}
test_only_ha_runs_post_ha_health() {
    setup_orchestrator_workspace; install_passing_mocks; write_mock_seed_script 0
    run_orchestrator --args "--only ha"
    assert_eq "$RUN_EXIT_CODE" "0" "--only ha with healthy post-checks → exit 0"
    assert_eq "$(proof_call_count ha)" "1" "--only ha still calls HA proof"
    assert_contains "$(cat "$TEST_CALL_LOG")" "http://localhost:3001/health" \
        "--only ha still checks API health after HA proof"
    assert_contains "$(cat "$TEST_CALL_LOG")" "http://127.0.0.1:7700/health" \
        "--only ha still checks target Flapjack health after HA proof"
}
# ============================================================================
# Failure Classification Tests
# ============================================================================
test_failure_commerce_exits_nonzero() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 1
    write_mock_proof_script cold-storage 0
    write_mock_proof_script ha 0
    run_orchestrator
    assert_eq "$((RUN_EXIT_CODE != 0 ? 1 : 0))" "1" "commerce fail → non-zero exit"
    assert_contains "$RUN_OUTPUT" "commerce" "output classifies commerce failure"
}
test_failure_cold_storage_exits_nonzero() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 0
    write_mock_proof_script cold-storage 1
    write_mock_proof_script ha 0
    run_orchestrator
    assert_eq "$((RUN_EXIT_CODE != 0 ? 1 : 0))" "1" "cold-storage fail → non-zero exit"
    assert_contains "$RUN_OUTPUT" "cold-storage" "output classifies cold-storage failure"
}
test_failure_ha_exits_nonzero() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 0
    write_mock_proof_script cold-storage 0
    write_mock_proof_script ha 1
    run_orchestrator
    assert_eq "$((RUN_EXIT_CODE != 0 ? 1 : 0))" "1" "HA fail → non-zero exit"
    assert_contains "$RUN_OUTPUT" "FAIL" "HA failure surfaced in output"
}
test_failure_first_fail_stops_execution() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 1
    write_mock_proof_script cold-storage 0
    write_mock_proof_script ha 0
    run_orchestrator
    assert_eq "$(call_log_line_count)" "1" "first failure stops execution (1 call)"
    assert_eq "$(proof_call_count cold-storage)" "0" "cold-storage not called after commerce fails"
    assert_eq "$(proof_call_count ha)" "0" "HA not called after commerce fails"
}
test_failure_cold_storage_stops_ha() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 0
    write_mock_proof_script cold-storage 1
    write_mock_proof_script ha 0
    run_orchestrator
    assert_eq "$(proof_call_count ha)" "0" "HA not called after cold-storage fails"
}
# ============================================================================
# Summary Output Tests
# ============================================================================
test_summary_all_pass_json() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    local artifact_dir
    artifact_dir=$(find_artifact_dir 2>/dev/null || true)
    if [ -z "$artifact_dir" ] || [ ! -f "$artifact_dir/summary.json" ]; then
        fail "all-pass summary.json should exist in artifact dir"
        return
    fi
    local json
    json=$(cat "$artifact_dir/summary.json")
    assert_valid_json "$json" "summary.json is valid JSON"
    assert_contains "$json" '"overall"' "summary has overall field"
    assert_contains "$json" '"pass"' "summary reports overall: pass"
}
test_summary_failure_json_classification() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 1
    write_mock_proof_script cold-storage 0
    write_mock_proof_script ha 0
    run_orchestrator
    local artifact_dir
    artifact_dir=$(find_artifact_dir 2>/dev/null || true)
    if [ -z "$artifact_dir" ] || [ ! -f "$artifact_dir/summary.json" ]; then
        fail "failure summary.json should exist in artifact dir"
        return
    fi
    local json
    json=$(cat "$artifact_dir/summary.json")
    assert_valid_json "$json" "failure summary.json is valid JSON"
    assert_contains "$json" '"fail"' "summary reports overall: fail"
    assert_contains "$json" '"not_run"' "unattempted proofs marked not_run"
}
test_summary_human_readable_all_pass() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    assert_contains "$RUN_OUTPUT" "PASS" "human summary shows PASS"
}
test_summary_human_readable_partial_failure() {
    setup_orchestrator_workspace
    write_mock_proof_script commerce 1
    write_mock_proof_script cold-storage 0
    write_mock_proof_script ha 0
    run_orchestrator
    assert_contains "$RUN_OUTPUT" "FAIL" "human summary shows FAIL"
    assert_contains "$RUN_OUTPUT" "SKIP" "human summary shows SKIPPED for unattempted"
}
# ============================================================================
# Artifact Dir Tests
# ============================================================================
test_artifact_dir_created() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    local artifact_dir
    artifact_dir=$(find_artifact_dir 2>/dev/null || true)
    if [ -n "$artifact_dir" ] && [ -d "$artifact_dir" ]; then
        pass "orchestrator artifact dir created"
    else
        fail "orchestrator artifact dir should be created under TMPDIR"
    fi
}
test_artifact_dir_has_summary_json() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    local artifact_dir
    artifact_dir=$(find_artifact_dir 2>/dev/null || true)
    if [ -n "$artifact_dir" ] && [ -f "$artifact_dir/summary.json" ]; then
        pass "summary.json written to artifact dir"
    else
        fail "summary.json should be written to artifact dir"
    fi
}
test_artifact_dir_path_in_output() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator
    assert_contains "$RUN_OUTPUT" "fjcloud-local-signoff" \
        "artifact dir path printed in output"
}
# ============================================================================
# --only CLI Scoping Tests
# ============================================================================
test_only_commerce() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator --args "--only commerce"
    assert_eq "$RUN_EXIT_CODE" "0" "--only commerce → exit 0"
    assert_eq "$(proof_call_count commerce)" "1" "--only commerce calls commerce"
    assert_eq "$(proof_call_count cold-storage)" "0" "--only commerce skips cold-storage"
    assert_eq "$(proof_call_count ha)" "0" "--only commerce skips HA"
}
test_only_cold_storage() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator --args "--only cold-storage"
    assert_eq "$RUN_EXIT_CODE" "0" "--only cold-storage → exit 0"
    assert_eq "$(proof_call_count commerce)" "0" "--only cold-storage skips commerce"
    assert_eq "$(proof_call_count cold-storage)" "1" "--only cold-storage calls cold-storage"
    assert_eq "$(proof_call_count ha)" "0" "--only cold-storage skips HA"
}
test_only_ha() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator --args "--only ha"
    assert_eq "$RUN_EXIT_CODE" "0" "--only ha → exit 0"
    assert_eq "$(proof_call_count commerce)" "0" "--only ha skips commerce"
    assert_eq "$(proof_call_count cold-storage)" "0" "--only ha skips cold-storage"
    assert_eq "$(proof_call_count ha)" "1" "--only ha calls HA"
}
test_only_invalid() {
    setup_orchestrator_workspace; install_passing_mocks
    run_orchestrator --args "--only invalid"
    assert_eq "$RUN_EXIT_CODE" "1" "--only invalid → exit 1"
    assert_contains "$RUN_OUTPUT" "invalid" "--only invalid mentions the bad value"
}
# ============================================================================
# Repo Entrypoint Contract Tests
# ============================================================================
test_repo_entrypoint_scripts_are_executable() {
    # These scripts are operator-facing entrypoints documented with direct
    # `./scripts/...` usage, so the executable bit is part of their contract.
    local script_path
    for script_path in \
        "$REPO_ROOT/scripts/seed_local.sh" \
        "$REPO_ROOT/scripts/local-signoff.sh" \
        "$REPO_ROOT/scripts/local-signoff-commerce.sh" \
        "$REPO_ROOT/scripts/local-signoff-cold-storage.sh" \
        "$REPO_ROOT/scripts/chaos/restart-region.sh"; do
        if [ -x "$script_path" ]; then
            pass "repo entrypoint is executable: ${script_path#$REPO_ROOT/}"
        else
            fail "repo entrypoint should be executable: ${script_path#$REPO_ROOT/}"
        fi
    done
}
# ============================================================================
# Run all tests
# ============================================================================
echo "=== local-signoff.sh orchestrator tests ==="
echo ""
echo "--- Env Preflight ---"
test_preflight_missing_stripe_local_mode
test_preflight_missing_cold_storage_endpoint
test_preflight_missing_flapjack_regions
test_preflight_skip_email_verification_set
echo ""
echo "--- Check Prerequisites ---"
test_check_prerequisites_exits_before_delegation_and_artifacts
test_check_prerequisites_loads_repo_env_file
test_check_prerequisites_reports_missing_docker
test_check_prerequisites_reports_missing_curl
test_check_prerequisites_reports_missing_jq
test_check_prerequisites_reports_malformed_flapjack_regions
test_check_prerequisites_rejects_duplicate_flapjack_regions
test_check_prerequisites_reports_malformed_database_url
test_check_prerequisites_does_not_leak_secret_values
test_check_prerequisites_accepts_explicit_flapjack_dev_dir_binary
test_check_prerequisites_accepts_later_candidate_binary_after_empty_dirs
test_check_prerequisites_accepts_default_repo_candidates_binary
test_check_prerequisites_accepts_path_flapjack_binary
test_check_prerequisites_fails_closed_without_flapjack_binary
echo ""
echo "--- Delegation Ordering ---"
test_delegation_all_pass_exit_zero
test_delegation_order
test_delegation_each_called_once
test_delegation_commerce_no_args
test_delegation_cold_storage_no_args
test_delegation_ha_receives_region
test_delegation_refreshes_seed_immediately_before_ha
test_delegation_seed_refresh_failure_stops_ha
test_post_ha_health_runs_after_full_ha_success
test_post_ha_health_failure_fails_signoff
test_only_ha_runs_post_ha_health
echo ""
echo "--- Failure Classification ---"
test_failure_commerce_exits_nonzero
test_failure_cold_storage_exits_nonzero
test_failure_ha_exits_nonzero
test_failure_first_fail_stops_execution
test_failure_cold_storage_stops_ha
echo ""
echo "--- Summary Output ---"
test_summary_all_pass_json
test_summary_failure_json_classification
test_summary_human_readable_all_pass
test_summary_human_readable_partial_failure
echo ""
echo "--- Artifact Dir ---"
test_artifact_dir_created
test_artifact_dir_has_summary_json
test_artifact_dir_path_in_output
echo ""
echo "--- --only CLI Scoping ---"
test_only_commerce
test_only_cold_storage
test_only_ha
test_only_invalid
echo ""
echo "--- Repo Entrypoints ---"
test_repo_entrypoint_scripts_are_executable
run_test_summary
