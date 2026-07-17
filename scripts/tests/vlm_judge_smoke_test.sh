#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/lib/test_runner.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"

# --- Sprint 1: Static existence and syntax checks ---

VLM_JUDGE="${REPO_ROOT}/scripts/vlm/vlm_judge.sh"
VLM_PROMPT="${REPO_ROOT}/scripts/vlm/lib/vlm_judge_prompt.sh"
VLM_ENV_HELPERS="${REPO_ROOT}/scripts/vlm/lib/vlm_env_helpers.sh"

# File existence
if [[ -f "${VLM_JUDGE}" ]]; then
    pass "vlm_judge.sh exists"
else
    fail "vlm_judge.sh missing at ${VLM_JUDGE}"
fi

if [[ -f "${VLM_PROMPT}" ]]; then
    pass "vlm_judge_prompt.sh exists"
else
    fail "vlm_judge_prompt.sh missing at ${VLM_PROMPT}"
fi

# Syntax validation (bash -n)
if bash -n "${VLM_JUDGE}" 2>/dev/null; then
    pass "vlm_judge.sh parses cleanly"
else
    fail "vlm_judge.sh has syntax errors"
fi

if bash -n "${VLM_PROMPT}" 2>/dev/null; then
    pass "vlm_judge_prompt.sh parses cleanly"
else
    fail "vlm_judge_prompt.sh has syntax errors"
fi

# Static source-line checks (grep, not execution)
if grep -q 'source.*lib/vlm_env_helpers\.sh' "${VLM_JUDGE}"; then
    pass "vlm_judge.sh sources vlm_env_helpers.sh"
else
    fail "vlm_judge.sh missing source line for vlm_env_helpers.sh"
fi

if grep -q 'source.*lib/vlm_judge_prompt\.sh' "${VLM_JUDGE}"; then
    pass "vlm_judge.sh sources vlm_judge_prompt.sh"
else
    fail "vlm_judge.sh missing source line for vlm_judge_prompt.sh"
fi

# Verify no residual deployment_common.sh reference
if grep -q 'deployment_common' "${VLM_JUDGE}"; then
    fail "vlm_judge.sh still references deployment_common.sh"
else
    pass "vlm_judge.sh has no deployment_common.sh reference"
fi

# --- Sprint 2: Helper contract checks ---

if [[ -f "${VLM_ENV_HELPERS}" ]]; then
    pass "vlm_env_helpers.sh exists"

    if bash -n "${VLM_ENV_HELPERS}" 2>/dev/null; then
        pass "vlm_env_helpers.sh parses cleanly"
    else
        fail "vlm_env_helpers.sh has syntax errors"
    fi

    # Functional contract: read_env_value_trimmed trims whitespace
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' EXIT
    printf 'ANTHROPIC_API_KEY=  sk-test-123  \n' > "${tmpdir}/.env.secret"

    trimmed_result="$(
        source "${VLM_ENV_HELPERS}"
        read_env_value_trimmed "${tmpdir}/.env.secret" "ANTHROPIC_API_KEY"
    )"
    assert_eq "${trimmed_result}" "sk-test-123" "read_env_value_trimmed strips whitespace"

    # Functional contract: missing key returns blank
    missing_result="$(
        source "${VLM_ENV_HELPERS}"
        read_env_value_trimmed "${tmpdir}/.env.secret" "NONEXISTENT_KEY"
    )"
    assert_eq "${missing_result}" "" "read_env_value_trimmed returns blank on missing key"

    # Functional contract: read_env_value_raw handles export prefix
    printf 'export MY_VAR=hello_world\n' > "${tmpdir}/.env.export"
    export_result="$(
        source "${VLM_ENV_HELPERS}"
        read_env_value_raw "${tmpdir}/.env.export" "MY_VAR"
    )"
    assert_eq "${export_result}" "hello_world" "read_env_value_raw handles export prefix"
else
    fail "vlm_env_helpers.sh missing at ${VLM_ENV_HELPERS}"
fi

# --- Sprint 3: Judgment schema enforcement checks ---

if [[ -f "${VLM_PROMPT}" ]]; then
    response_with_null_rule_id='{"content":[{"type":"text","text":"{\"screen\":\"auth__dashboard__loading__mobile_narrow.png\",\"score\":10,\"verdict\":\"fail\",\"summary\":\"bad\",\"violations\":[{\"rule_id\":null,\"description\":\"missing anchor\"}],\"actions\":[]}"}]}'
    if (
        source "${VLM_PROMPT}"
        extract_vlm_judgment_json "${response_with_null_rule_id}" >/dev/null 2>&1
    ); then
        fail "extract_vlm_judgment_json rejects null violations[].rule_id"
    else
        pass "extract_vlm_judgment_json rejects null violations[].rule_id"
    fi

    response_with_empty_description='{"content":[{"type":"text","text":"{\"screen\":\"auth__dashboard__loading__mobile_narrow.png\",\"score\":10,\"verdict\":\"fail\",\"summary\":\"bad\",\"violations\":[{\"rule_id\":\"M.universal.1\",\"description\":\"\"}],\"actions\":[]}"}]}'
    if (
        source "${VLM_PROMPT}"
        extract_vlm_judgment_json "${response_with_empty_description}" >/dev/null 2>&1
    ); then
        fail "extract_vlm_judgment_json rejects empty violations[].description"
    else
        pass "extract_vlm_judgment_json rejects empty violations[].description"
    fi

    response_with_valid_violation='{"content":[{"type":"text","text":"{\"screen\":\"auth__dashboard__loading__mobile_narrow.png\",\"score\":10,\"verdict\":\"fail\",\"summary\":\"bad\",\"violations\":[{\"rule_id\":\"M.universal.1\",\"description\":\"Cream surface missing\"}],\"actions\":[]}"}]}'
    if (
        source "${VLM_PROMPT}"
        extract_vlm_judgment_json "${response_with_valid_violation}" >/dev/null 2>&1
    ); then
        pass "extract_vlm_judgment_json accepts non-empty violations[].rule_id and description"
    else
        fail "extract_vlm_judgment_json should accept non-empty violations[].rule_id and description"
    fi
fi

run_test_summary
