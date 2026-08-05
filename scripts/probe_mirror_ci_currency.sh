#!/usr/bin/env bash
# Report whether staging and prod mirror CI is green at each mirror's current HEAD.
#
# This read-only visibility owner is intentionally separate from two adjacent
# contracts: launch/post_wave_a_sync_prod.sh::staging_green_gate enforces
# staging provenance plus CI during promotion, while canary/deploy_currency_check.sh
# measures deployed-commit drift. Neither enforcement nor drift belongs here.

set -euo pipefail

readonly STAGING_REPO="gridl-infra-staging/fjcloud"
readonly PROD_REPO="gridl-infra-prod/fjcloud"
readonly GH_RUN_FIELDS="name,event,conclusion,createdAt,headSha,databaseId,status"

fixture_path=""
fixture_head_sha=""

usage() {
    printf 'Usage: %s [--fixture <runs.json> --fixture-head-sha <sha>]\n' "${0##*/}" >&2
}

emit_verdict() {
    local repo="$1" mirror_head="$2" run_id="$3" status="$4"
    local conclusion="$5" run_head_sha="$6" age_seconds="$7" reason="$8"
    printf 'repo=%s mirror_head=%s run_id=%s status=%s conclusion=%s run_head_sha=%s age_seconds=%s reason=%s\n' \
        "$repo" "$mirror_head" "$run_id" "$status" "$conclusion" \
        "$run_head_sha" "$age_seconds" "$reason"
}

emit_unavailable_for_both() {
    local reason="$1"
    emit_verdict "$STAGING_REPO" unknown none none none none unknown "$reason"
    emit_verdict "$PROD_REPO" unknown none none none none unknown "$reason"
}

is_sha() {
    [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture)
                [ "$#" -ge 2 ] || return 2
                fixture_path="$2"
                shift 2
                ;;
            --fixture-head-sha)
                [ "$#" -ge 2 ] || return 2
                fixture_head_sha="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                return 2
                ;;
        esac
    done

    if { [ -n "$fixture_path" ] && [ -z "$fixture_head_sha" ]; } \
        || { [ -z "$fixture_path" ] && [ -n "$fixture_head_sha" ]; }; then
        return 2
    fi
    if [ -n "$fixture_head_sha" ] && ! is_sha "$fixture_head_sha"; then
        return 2
    fi
}

runs_json_has_expected_shape() {
    local runs_path="$1"
    [ -s "$runs_path" ] || return 1
    jq -e '
        type == "array" and all(.[];
            type == "object" and
            (.name | type == "string") and
            (.event | type == "string") and
            ((.conclusion | type == "string") or .conclusion == null) and
            (.createdAt | type == "string") and
            (.createdAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
            (.headSha | type == "string") and
            (.databaseId | type == "number") and
            (.status | type == "string")
        )
    ' "$runs_path" >/dev/null 2>&1
}

newest_ci_push_run() {
    local runs_path="$1"
    jq -r '
        map(select(.name == "CI" and .event == "push"))
        | sort_by(.createdAt)
        | last
        | if . == null then empty
          else [.databaseId, .status, (if .conclusion == null or .conclusion == "" then "none" else .conclusion end), .headSha, .createdAt] | @tsv
          end
    ' "$runs_path"
}

run_age_seconds() {
    local created_at="$1"
    python3 - "$created_at" <<'PY'
import sys
from datetime import datetime, timezone

created_at = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
age_seconds = int((datetime.now(timezone.utc) - created_at).total_seconds())
print(max(0, age_seconds))
PY
}

classify_runs() {
    local repo="$1" mirror_head="$2" runs_path="$3"
    local selected run_id status conclusion run_head_sha created_at age_seconds

    if ! runs_json_has_expected_shape "$runs_path"; then
        emit_verdict "$repo" "$mirror_head" none none none none unknown malformed_output
        return 1
    fi

    selected="$(newest_ci_push_run "$runs_path")"
    if [ -z "$selected" ]; then
        emit_verdict "$repo" "$mirror_head" none none none none unknown ci_run_missing
        return 1
    fi

    IFS=$'\t' read -r run_id status conclusion run_head_sha created_at <<< "$selected"
    if ! age_seconds="$(run_age_seconds "$created_at" 2>/dev/null)"; then
        emit_verdict "$repo" "$mirror_head" "$run_id" "$status" "$conclusion" "$run_head_sha" unknown malformed_output
        return 1
    fi

    if [ "$run_head_sha" != "$mirror_head" ]; then
        emit_verdict "$repo" "$mirror_head" "$run_id" "$status" "$conclusion" "$run_head_sha" "$age_seconds" ci_head_mismatch
        return 1
    fi
    if [ "$status" != "completed" ]; then
        emit_verdict "$repo" "$mirror_head" "$run_id" "$status" "$conclusion" "$run_head_sha" "$age_seconds" ci_not_completed
        return 1
    fi
    if [ "$conclusion" != "success" ]; then
        emit_verdict "$repo" "$mirror_head" "$run_id" "$status" "$conclusion" "$run_head_sha" "$age_seconds" ci_non_success
        return 1
    fi

    emit_verdict "$repo" "$mirror_head" "$run_id" "$status" "$conclusion" "$run_head_sha" "$age_seconds" green
}

probe_repository() {
    local repo="$1" mirror_head runs_path query_rc=0

    if ! mirror_head="$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha' 2>/dev/null)" \
        || ! is_sha "$mirror_head"; then
        emit_verdict "$repo" unknown none none none none unknown api_failure
        return 1
    fi

    runs_path="$(mktemp)" || {
        emit_verdict "$repo" "$mirror_head" none none none none unknown api_failure
        return 1
    }
    gh run list -R "$repo" --limit 100 --json "$GH_RUN_FIELDS" > "$runs_path" 2>/dev/null || query_rc=$?
    if [ "$query_rc" -ne 0 ]; then
        rm -f "$runs_path"
        emit_verdict "$repo" "$mirror_head" none none none none unknown api_failure
        return 1
    fi

    classify_runs "$repo" "$mirror_head" "$runs_path"
    query_rc=$?
    rm -f "$runs_path"
    return "$query_rc"
}

if ! parse_arguments "$@"; then
    usage
    emit_verdict fixture/fjcloud "${fixture_head_sha:-unknown}" none none none none unknown invalid_arguments
    exit 2
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    if [ -n "$fixture_path" ]; then
        emit_verdict fixture/fjcloud "$fixture_head_sha" none none none none unknown malformed_output
    else
        emit_unavailable_for_both api_failure
    fi
    exit 1
fi

if [ -n "$fixture_path" ]; then
    classify_runs fixture/fjcloud "$fixture_head_sha" "$fixture_path"
    exit $?
fi

# An explicit empty token is an operator-requested fail-closed negative control;
# do not allow gh to silently fall back to credentials stored on the host.
if [ "${GH_TOKEN+x}" = "x" ] && [ -z "$GH_TOKEN" ]; then
    emit_unavailable_for_both auth_missing
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    emit_unavailable_for_both api_failure
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    emit_unavailable_for_both auth_missing
    exit 1
fi

aggregate_rc=0
probe_repository "$STAGING_REPO" || aggregate_rc=1
probe_repository "$PROD_REPO" || aggregate_rc=1
exit "$aggregate_rc"
