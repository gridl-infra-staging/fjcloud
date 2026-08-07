#!/usr/bin/env bash
# Fail-closed liveness and acknowledged-health probe for scheduled mirror workflows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WORKFLOW_REGISTRY="${SCHEDULED_ALARM_WORKFLOW_REGISTRY:-$REPO_ROOT/scripts/tests/scheduled_alarm_workflows.txt}"
ACK_REGISTRY="${SCHEDULED_ALARM_ACK_REGISTRY:-$REPO_ROOT/scripts/tests/scheduled_alarm_acknowledgements.txt}"
# shellcheck source=scripts/lib/mirror_github.sh
source "$SCRIPT_DIR/lib/mirror_github.sh"
# shellcheck source=scripts/lib/registry_owner.sh
source "$SCRIPT_DIR/lib/registry_owner.sh"
# shellcheck source=scripts/lib/scheduled_workflows.sh
source "$SCRIPT_DIR/lib/scheduled_workflows.sh"

fixture_dir=""
now_epoch=""
checked_count=0
passed_count=0
failed_count=0
registry_mismatch=0
WORK_DIR="$(mktemp -d)"
NORMALIZED_WORKFLOWS="$WORK_DIR/workflows.txt"
NORMALIZED_ACKS="$WORK_DIR/acknowledgements.txt"
trap 'rm -rf "$WORK_DIR"' EXIT
: > "$NORMALIZED_WORKFLOWS"
: > "$NORMALIZED_ACKS"

usage() {
    printf 'Usage: %s [--fixture-dir <dir> --now-epoch <epoch>]\n' "${0##*/}" >&2
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture-dir) [ "$#" -ge 2 ] || return 1; fixture_dir="$2"; shift 2 ;;
            --now-epoch) [ "$#" -ge 2 ] || return 1; now_epoch="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) return 1 ;;
        esac
    done
    if { [ -n "$fixture_dir" ] && [ -z "$now_epoch" ]; } ||
        { [ -z "$fixture_dir" ] && [ -n "$now_epoch" ]; }; then
        return 1
    fi
    [ -z "$now_epoch" ] || [[ "$now_epoch" =~ ^[0-9]+$ ]]
}

trim_space() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

load_workflow_registry() {
    local line trimmed mirror workflow expectation freshness extra line_number=0
    [ -f "$WORKFLOW_REGISTRY" ] || { registry_mismatch=1; return; }
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        trimmed="$(trim_space "$line")"
        [ -n "$trimmed" ] && [[ "$trimmed" != \#* ]] || continue
        read -r mirror workflow expectation freshness extra <<< "$trimmed"
        if [ -n "${extra:-}" ] || [[ ! "$mirror" =~ ^(staging|prod)$ ]] ||
            [[ ! "$workflow" =~ ^[[:alnum:]_]+\.ya?ml$ ]] ||
            [[ ! "$expectation" =~ ^(run|skip)$ ]] ||
            [[ ! "$freshness" =~ ^[1-9][0-9]*$ ]]; then
            printf 'registry_error file=%s line=%s reason=malformed_workflow_row\n' "${WORKFLOW_REGISTRY#"$REPO_ROOT/"}" "$line_number"
            registry_mismatch=1
            continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$mirror" "$workflow" "$expectation" "$freshness" >> "$NORMALIZED_WORKFLOWS"
    done < "$WORKFLOW_REGISTRY"

    if [ "$(LC_ALL=C sort "$NORMALIZED_WORKFLOWS" | uniq | wc -l | tr -d ' ')" != "$(wc -l < "$NORMALIZED_WORKFLOWS" | tr -d ' ')" ]; then
        printf 'registry_error reason=duplicate_workflow_pair\n'
        registry_mismatch=1
    fi
    validate_declared_denominator
}

validate_declared_denominator() {
    local expected_pairs declared_pairs workflow mirror
    expected_pairs="$WORK_DIR/expected_pairs.txt"
    declared_pairs="$WORK_DIR/declared_pairs.txt"
    : > "$expected_pairs"
    while IFS= read -r workflow; do
        for mirror in staging prod; do printf '%s\t%s\n' "$mirror" "$workflow"; done
    done < <(scheduled_workflow_files "$REPO_ROOT") | LC_ALL=C sort > "$expected_pairs"
    cut -f1,2 "$NORMALIZED_WORKFLOWS" | LC_ALL=C sort > "$declared_pairs"
    if ! cmp -s "$expected_pairs" "$declared_pairs"; then
        printf 'registry_error reason=scheduled_workflow_denominator_mismatch\n'
        registry_mismatch=1
    fi
}

load_acknowledgements() {
    local line trimmed entry reason mirror workflow job line_number=0
    [ -f "$ACK_REGISTRY" ] || { printf 'registry_error reason=acknowledgement_registry_missing\n'; registry_mismatch=1; return; }
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        trimmed="$(trim_space "$line")"
        [ -n "$trimmed" ] && [[ "$trimmed" != \#* ]] || continue
        if [[ "$trimmed" != *" # "* ]]; then
            printf 'registry_error file=%s line=%s reason=malformed_acknowledgement_row\n' "${ACK_REGISTRY#"$REPO_ROOT/"}" "$line_number"
            registry_mismatch=1
            continue
        fi
        entry="${trimmed%% # *}"
        reason="${trimmed#* # }"
        if [[ "$entry" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
            mirror="${BASH_REMATCH[1]}"
            workflow="${BASH_REMATCH[2]}"
            job="$(trim_space "${BASH_REMATCH[3]}")"
        else
            mirror=""
            workflow=""
            job=""
        fi
        if [[ ! "$mirror" =~ ^(staging|prod)$ ]] ||
            [[ ! "$workflow" =~ ^[[:alnum:]_]+\.ya?ml$ ]] || [ -z "$job" ] ||
            [[ "$job" == *$'\t'* ]] ||
            [[ "$reason" == *ROADMAP.md:* ]] || ! registry_reason_has_owner "$REPO_ROOT" "$reason"; then
            printf 'registry_error file=%s line=%s reason=invalid_acknowledgement_owner\n' "${ACK_REGISTRY#"$REPO_ROOT/"}" "$line_number"
            registry_mismatch=1
            continue
        fi
        printf '%s\t%s\t%s\n' "$mirror" "$workflow" "$job" >> "$NORMALIZED_ACKS"
    done < "$ACK_REGISTRY"
    if [ "$(LC_ALL=C sort "$NORMALIZED_ACKS" | uniq | wc -l | tr -d ' ')" != "$(wc -l < "$NORMALIZED_ACKS" | tr -d ' ')" ]; then
        printf 'registry_error reason=duplicate_acknowledgement_key\n'
        registry_mismatch=1
    fi
}

repo_for_mirror() {
    if [ "$1" = staging ]; then printf '%s' "$STAGING_REPO"; else printf '%s' "$PROD_REPO"; fi
}

fetch_response() {
    local mirror="$1" workflow="$2" response_kind="$3" run_id="$4" output_path="$5" repo endpoint
    if [ -n "$fixture_dir" ]; then
        cp "$fixture_dir/${mirror}_${workflow}.${response_kind}.json" "$output_path" 2>/dev/null
        return $?
    fi
    repo="$(repo_for_mirror "$mirror")"
    if [ "$response_kind" = runs ]; then
        endpoint="repos/$repo/actions/workflows/$workflow/runs?event=schedule&per_page=1"
    else
        endpoint="repos/$repo/actions/runs/$run_id/jobs?per_page=100"
    fi
    github_api_to_file "$endpoint" "$output_path"
}

run_age_seconds() {
    local created_at="$1"
    python3 - "$created_at" "${now_epoch:-}" <<'PY'
import sys
from datetime import datetime, timezone

created = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
now = datetime.fromtimestamp(int(sys.argv[2]), timezone.utc) if sys.argv[2] else datetime.now(timezone.utc)
age = int((now - created).total_seconds())
if age < 0:
    sys.exit(2)
print(age)
PY
}

format_run_evidence() {
    printf 'run_id=%s status=%s conclusion=%s age_seconds=%s' "$1" "$2" "$3" "$4"
}

emit_verdict() {
    local mirror="$1" workflow="$2" run_evidence="$3" failing_job="$4" reason="$5" verdict_rc="${6:-1}"
    printf 'mirror=%s workflow=%s %s failing_job=%s reason=%s\n' \
        "$mirror" "$workflow" "$run_evidence" "$failing_job" "$reason"
    checked_count=$((checked_count + 1))
    if [ "$verdict_rc" -eq 0 ]; then passed_count=$((passed_count + 1)); else failed_count=$((failed_count + 1)); fi
}

acknowledgement_exists() {
    local mirror="$1" workflow="$2" job="$3"
    awk -F '\t' -v m="$mirror" -v w="$workflow" -v j="$job" '$1==m && $2==w && $3==j {found=1} END{exit !found}' "$NORMALIZED_ACKS"
}

valid_runs_payload() {
    local runs_path="$1"
    jq -e '
        def run_status:
            . == "queued" or . == "in_progress" or . == "completed" or
            . == "waiting" or . == "requested" or . == "pending";
        # GitHub REST OpenAPI workflow-run conclusion enum, excluding null.
        def run_terminal_conclusion:
            . == "success" or . == "failure" or . == "neutral" or
            . == "cancelled" or . == "skipped" or . == "timed_out" or
            . == "action_required" or . == "startup_failure" or . == "stale";
        type == "object"
        and (.total_count | type == "number" and . >= 0 and floor == .)
        and (.workflow_runs | type == "array")
        # per_page=1: the returned array length must equal min(total_count, 1),
        # so internally inconsistent metadata cannot yield a healthy verdict.
        and ((.workflow_runs | length) == (if .total_count >= 1 then 1 else 0 end))
        and all(.workflow_runs[];
            type == "object"
            and (.id | type == "number")
            and (.status | type == "string" and run_status)
            and (has("conclusion") and ((.conclusion == null) or (.conclusion | type == "string")))
            and (if .status == "completed"
                then (.conclusion | type == "string" and run_terminal_conclusion)
                else .conclusion == null
                end)
            and (.created_at | type == "string")
        )
    ' "$runs_path" >/dev/null 2>&1
}

valid_jobs_payload() {
    local jobs_path="$1"
    jq -e '
        # GitHub REST OpenAPI job conclusion enum, excluding null.
        def job_terminal_conclusion:
            . == "success" or . == "failure" or . == "neutral" or
            . == "cancelled" or . == "skipped" or . == "timed_out" or
            . == "action_required";
        type == "object"
        and (.total_count | type == "number" and . >= 0 and floor == .)
        and (.jobs | type == "array")
        and ((.jobs | length) == .total_count)
        and all(.jobs[];
            type == "object"
            and (.name | type == "string")
            and (.conclusion | type == "string")
            and (.conclusion | job_terminal_conclusion)
        )
    ' "$jobs_path" >/dev/null 2>&1
}

is_red_conclusion() {
    [ "$1" != success ] && [ "$1" != skipped ]
}

fetch_valid_jobs() {
    local mirror="$1" workflow="$2" run_id="$3" jobs_path="$4"
    fetch_response "$mirror" "$workflow" jobs "$run_id" "$jobs_path" && valid_jobs_payload "$jobs_path"
}

failing_job_names() {
    jq -r '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required") | .name' "$1"
}

# Print the failing job evidence for a red run without deciding its verdict:
# comma-joined failing job names, "unknown" when the jobs payload is
# unreachable/malformed, or "none" when no job carries a failing conclusion.
resolve_failing_job_display() {
    local mirror="$1" workflow="$2" run_id="$3" jobs_path="$WORK_DIR/jobs.json" names
    if ! fetch_valid_jobs "$mirror" "$workflow" "$run_id" "$jobs_path"; then
        printf 'unknown'
        return 1
    fi
    names="$(failing_job_names "$jobs_path")"
    [ -n "$names" ] || { printf 'none'; return; }
    printf '%s' "$names" | paste -sd, -
}

classify_red_run() {
    local mirror="$1" workflow="$2" run_id="$3" status="$4" conclusion="$5" age="$6"
    local jobs_path="$WORK_DIR/jobs.json" failing_jobs failing_job all_acknowledged=1
    if ! fetch_valid_jobs "$mirror" "$workflow" "$run_id" "$jobs_path"; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" unknown api_failure
        return
    fi
    failing_jobs="$(failing_job_names "$jobs_path")"
    if [ -z "$failing_jobs" ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" unknown failing_job_missing
        return
    fi
    while IFS= read -r failing_job; do
        if [ "$workflow" = deploy_currency.yml ] || ! acknowledgement_exists "$mirror" "$workflow" "$failing_job"; then
            all_acknowledged=0
        fi
    done <<< "$failing_jobs"
    failing_jobs="$(printf '%s\n' "$failing_jobs" | paste -sd, -)"
    if [ "$all_acknowledged" -eq 1 ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" "$failing_jobs" red_acknowledged 0
    else
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" "$failing_jobs" red_unacknowledged
    fi
}

probe_pair() {
    local mirror="$1" workflow="$2" expectation="$3" freshness="$4"
    local runs_path="$WORK_DIR/runs.json" selected run_id status conclusion created_at age age_status
    if ! fetch_response "$mirror" "$workflow" runs none "$runs_path" ||
        ! valid_runs_payload "$runs_path"; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence none none none unknown)" none api_failure
        return
    fi
    selected="$(jq -r '.workflow_runs | first | if . == null then empty else [.id, .status, (.conclusion // "none"), .created_at] | @tsv end' "$runs_path")"
    if [ -z "$selected" ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence none none none unknown)" none schedule_run_missing
        return
    fi
    IFS=$'\t' read -r run_id status conclusion created_at <<< "$selected"
    if age="$(run_age_seconds "$created_at" 2>/dev/null)"; then
        :
    else
        age_status=$?
        if [ "$age_status" -eq 2 ]; then
            emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" unknown)" none timestamp_in_future
            return
        fi
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" unknown)" none api_failure
        return
    fi
    if [ "$status" != completed ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" none not_completed
    elif [ "$age" -gt "$freshness" ]; then
        # A stale run still fails for staleness, but a stale red run must keep
        # its failing-job evidence instead of hiding it behind failing_job=none.
        local stale_job=none
        if is_red_conclusion "$conclusion"; then
            if stale_job="$(resolve_failing_job_display "$mirror" "$workflow" "$run_id")"; then
                emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" "$stale_job" stale
            else
                emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" "$stale_job" api_failure
            fi
        else
            emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" "$stale_job" stale
        fi
    elif [ "$conclusion" = skipped ] && [ "$expectation" = skip ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" none skip_expected 0
    elif [ "$conclusion" = skipped ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" none unexpected_skip
    elif [ "$conclusion" = success ] && [ "$expectation" = run ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" none green 0
    elif [ "$conclusion" = success ]; then
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence "$run_id" "$status" "$conclusion" "$age")" none expected_skip_missing
    else
        classify_red_run "$mirror" "$workflow" "$run_id" "$status" "$conclusion" "$age"
    fi
}

emit_access_failure() {
    local reason="$1" mirror workflow expectation freshness
    while IFS=$'\t' read -r mirror workflow expectation freshness; do
        emit_verdict "$mirror" "$workflow" "$(format_run_evidence none none none unknown)" none "$reason"
    done < "$NORMALIZED_WORKFLOWS"
}

print_summary_and_exit() {
    if [ "$registry_mismatch" -ne 0 ]; then
        failed_count=$((failed_count + 1))
        printf 'summary checked=%s passed=%s failed=%s reason=registry_mismatch\n' "$checked_count" "$passed_count" "$failed_count"
    else
        printf 'summary checked=%s passed=%s failed=%s\n' "$checked_count" "$passed_count" "$failed_count"
    fi
    [ "$failed_count" -eq 0 ]
}

if ! parse_arguments "$@"; then usage; exit 2; fi
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    printf 'summary checked=0 passed=0 failed=1 reason=api_failure\n'
    exit 1
fi
load_workflow_registry
load_acknowledgements
if [ -z "$fixture_dir" ] && access_failure_reason="$(github_access_failure_reason)"; then
    emit_access_failure "$access_failure_reason"
    print_summary_and_exit
    exit $?
fi
while IFS=$'\t' read -r mirror workflow expectation freshness; do
    probe_pair "$mirror" "$workflow" "$expectation" "$freshness"
done < "$NORMALIZED_WORKFLOWS"
print_summary_and_exit
