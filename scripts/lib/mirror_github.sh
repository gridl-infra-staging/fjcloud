#!/usr/bin/env bash
# Source-only owner for fjcloud mirror identities and GitHub access posture.

# The constants are consumed by sourcing probes rather than this file itself.
# shellcheck disable=SC2034
readonly STAGING_REPO="gridl-infra-staging/fjcloud"
# shellcheck disable=SC2034
readonly PROD_REPO="gridl-infra-prod/fjcloud"

github_access_failure_reason() {
    if [ "${GH_TOKEN+x}" = "x" ] && [ -z "$GH_TOKEN" ]; then
        printf '%s' auth_missing
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        printf '%s' api_failure
        return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        printf '%s' auth_missing
        return 0
    fi
    return 1
}

github_api_to_file() {
    local endpoint="$1" output_path="$2"
    gh api "$endpoint" > "$output_path" 2>/dev/null
}
