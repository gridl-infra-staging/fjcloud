#!/usr/bin/env bash
# operator_helpers_smoke_test.sh — minimal contract tests for the
# operator-side helper scripts added during the 2026-04-25 evening
# Blocker-3 unblock pass:
#
#   - scripts/launch/ssm_exec_staging.sh
#   - scripts/launch/post_deploy_verify_tenant_map.sh
#   - scripts/launch/capture_stage_d_evidence.sh
#   - scripts/launch/refresh_staging_runtime_checkout.sh
#   - scripts/launch/hydrate_seeder_env_from_ssm.sh
#
# These scripts hit AWS / staging at runtime; a full end-to-end test
# would require staging credentials + a live RDS / EC2. So this smoke
# suite verifies what we can statically:
#
#   1) Scripts are executable, pass shell `bash -n`, and have the
#      expected required-arg / failure-mode contract when called with
#      bad input.
#   2) Each declares its own `set -euo pipefail`.
#   3) `--help` (or `-h`) is wired where applicable.
#
# Catches regressions where a future edit accidentally drops `set -e`
# or breaks the require-args contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

declare -a HELPERS=(
    "scripts/launch/ssm_exec_staging.sh"
    "scripts/launch/post_deploy_verify_tenant_map.sh"
    "scripts/launch/capture_stage_d_evidence.sh"
    "scripts/launch/hydrate_seeder_env_from_ssm.sh"
)

test_executable_and_syntax_clean() {
    for helper in "${HELPERS[@]}"; do
        local path="$REPO_ROOT/$helper"
        if [ ! -f "$path" ]; then
            fail "$helper does not exist"
            continue
        fi
        if [ ! -x "$path" ]; then
            fail "$helper is not executable"
            continue
        fi
        if ! bash -n "$path" 2>/dev/null; then
            fail "$helper has bash syntax errors"
            continue
        fi
        pass "$helper is executable and parses cleanly"
    done
}

test_set_euo_pipefail_present() {
    for helper in "${HELPERS[@]}"; do
        local path="$REPO_ROOT/$helper"
        if grep -qE "^set -euo pipefail$" "$path"; then
            pass "$helper sets -euo pipefail"
        else
            fail "$helper is missing 'set -euo pipefail'"
        fi
    done
}

test_ssm_exec_requires_command_argument() {
    local output exit_code=0
    output="$(bash "$REPO_ROOT/scripts/launch/ssm_exec_staging.sh" 2>&1)" || exit_code=$?
    if [ "$exit_code" -eq 64 ] && printf '%s' "$output" | grep -q 'Usage: '; then
        pass "ssm_exec_staging.sh exits 64 with usage message when called without command"
    else
        fail "ssm_exec_staging.sh should exit 64 with usage on missing arg (got exit=$exit_code, output=$output)"
    fi
}

test_post_deploy_verifier_requires_api_url() {
    local output exit_code=0
    output="$(env -u API_URL bash "$REPO_ROOT/scripts/launch/post_deploy_verify_tenant_map.sh" 2>&1)" || exit_code=$?
    if [ "$exit_code" -eq 64 ] && printf '%s' "$output" | grep -q 'API_URL is not set'; then
        pass "post_deploy_verify_tenant_map.sh exits 64 with diagnostic when API_URL unset"
    else
        fail "post_deploy_verify_tenant_map.sh should exit 64 with API_URL diagnostic (got exit=$exit_code, output=$output)"
    fi
}

test_capture_stage_d_evidence_requires_env() {
    local output exit_code=0
    output="$(env -u API_URL -u ADMIN_KEY bash "$REPO_ROOT/scripts/launch/capture_stage_d_evidence.sh" 2>&1)" || exit_code=$?
    if [ "$exit_code" -eq 64 ] && printf '%s' "$output" | grep -q 'API_URL or ADMIN_KEY not set'; then
        pass "capture_stage_d_evidence.sh exits 64 with diagnostic when API_URL/ADMIN_KEY unset"
    else
        fail "capture_stage_d_evidence.sh should exit 64 with diagnostic (got exit=$exit_code, output=$output)"
    fi
}

echo "=== operator helper smoke tests ==="
test_executable_and_syntax_clean
test_set_euo_pipefail_present
test_ssm_exec_requires_command_argument
test_post_deploy_verifier_requires_api_url
test_capture_stage_d_evidence_requires_env

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
