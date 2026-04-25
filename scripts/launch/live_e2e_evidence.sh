#!/usr/bin/env bash

set -euo pipefail

# Live evidence can include sensitive operational details; keep wrapper-created
# artifacts private even when the caller's shell has a permissive umask.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_SMOKE_SCRIPT="$REPO_ROOT/ops/terraform/tests_stage7_runtime_smoke.sh"
BILLING_REHEARSAL_SCRIPT="$REPO_ROOT/scripts/staging_billing_rehearsal.sh"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/validation_json.sh
source "$REPO_ROOT/scripts/lib/validation_json.sh"

LIVE_E2E_ENV=""
LIVE_E2E_DOMAIN=""
LIVE_E2E_ARTIFACT_ROOT=""
LIVE_E2E_ENV_FILE=""
LIVE_E2E_AMI_ID=""
LIVE_E2E_BILLING_MONTH=""
LIVE_E2E_RUN_BILLING_REHEARSAL=0
LIVE_E2E_CONFIRM_LIVE_MUTATION=0
LIVE_E2E_RUNTIME_OWNER_ARGS=()
SHOW_HELP=0

RUN_ID=""
STARTED_AT=""
RUN_DIR=""
SUMMARY_PATH=""
LOGS_DIR=""

CHECK_ROWS_JSONL=""
CRED_CHECK_ROWS_JSONL=""
BLOCKER_ROWS_JSONL=""
CHECK_COUNT=0
FAIL_COUNT=0
BLOCKER_COUNT=0
RUNTIME_SMOKE_EXIT_CODE=0
BILLING_REHEARSAL_EXIT_CODE=0

REDACTION_VALUES=()

print_usage() {
    cat <<'USAGE'
Usage:
  live_e2e_evidence.sh --env <staging|prod> --domain <domain> --artifact-dir <dir> [--env-file <path>] [--ami-id <ami-id>] [--apply] [--run-deploy] [--run-migrate] [--run-rollback] [--alert-email <email>] [--release-sha <sha>] [--rollback-sha <sha>] [--run-billing-rehearsal --month <YYYY-MM> --confirm-live-mutation]
  live_e2e_evidence.sh --help
USAGE
}

parse_args_token() {
    local token="$1"
    local next_value="${2:-}"
    local arg_count="$3"

    PARSE_CONSUMED=1
    case "$token" in
        --help|-h)
            SHOW_HELP=1
            ;;
        --env|--domain|--artifact-dir|--env-file|--ami-id|--month|--alert-email|--release-sha|--rollback-sha)
            if [ "$arg_count" -lt 2 ] || [ -z "$next_value" ] || [[ "$next_value" == --* ]]; then
                echo "ERROR: $token requires a value" >&2
                print_usage >&2
                return 2
            fi
            case "$token" in
                --env)
                    LIVE_E2E_ENV="$next_value"
                    ;;
                --domain)
                    LIVE_E2E_DOMAIN="$next_value"
                    ;;
                --artifact-dir)
                    LIVE_E2E_ARTIFACT_ROOT="$next_value"
                    ;;
                --env-file)
                    LIVE_E2E_ENV_FILE="$next_value"
                    ;;
                --ami-id)
                    LIVE_E2E_AMI_ID="$next_value"
                    ;;
                --month)
                    LIVE_E2E_BILLING_MONTH="$next_value"
                    ;;
                --alert-email|--release-sha|--rollback-sha)
                    LIVE_E2E_RUNTIME_OWNER_ARGS+=("$token" "$next_value")
                    ;;
            esac
            PARSE_CONSUMED=2
            ;;
        --apply|--run-deploy|--run-migrate|--run-rollback)
            LIVE_E2E_RUNTIME_OWNER_ARGS+=("$token")
            ;;
        --run-billing-rehearsal)
            LIVE_E2E_RUN_BILLING_REHEARSAL=1
            ;;
        --confirm-live-mutation)
            LIVE_E2E_CONFIRM_LIVE_MUTATION=1
            ;;
        *)
            echo "ERROR: Unknown argument: $token" >&2
            print_usage >&2
            return 2
            ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        parse_args_token "$1" "${2:-}" "$#" || return 2
        shift "$PARSE_CONSUMED"
    done
}

validate_required_args() {
    if [ "$SHOW_HELP" -eq 1 ]; then
        return 0
    fi

    if [ -z "$LIVE_E2E_ENV" ]; then
        echo "ERROR: --env is required" >&2
        print_usage >&2
        return 2
    fi
    case "$LIVE_E2E_ENV" in
        staging|prod)
            ;;
        *)
            echo "ERROR: --env must be one of: staging|prod" >&2
            print_usage >&2
            return 2
            ;;
    esac
    if [ -z "$LIVE_E2E_DOMAIN" ]; then
        echo "ERROR: --domain is required" >&2
        print_usage >&2
        return 2
    fi
    if [ -z "$LIVE_E2E_ARTIFACT_ROOT" ]; then
        echo "ERROR: --artifact-dir is required" >&2
        print_usage >&2
        return 2
    fi
}

create_run_id() {
    printf 'fjcloud_live_e2e_evidence_%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

ensure_artifact_root() {
    local artifact_root="$1"
    if [ -e "$artifact_root" ] && [ ! -d "$artifact_root" ]; then
        echo "ERROR: --artifact-dir must be a directory path: $artifact_root" >&2
        return 1
    fi
    mkdir -p "$artifact_root"
}

create_run_dir() {
    local artifact_root="$1"
    local run_id="$2"
    local run_dir="$artifact_root/$run_id"
    mkdir -p "$run_dir"
    printf '%s\n' "$run_dir"
}

summary_path_for_run_dir() {
    local run_dir="$1"
    printf '%s/summary.json\n' "$run_dir"
}

logs_dir_for_run_dir() {
    local run_dir="$1"
    printf '%s/logs\n' "$run_dir"
}

add_redaction_value() {
    local value="$1"
    local seen

    [ -n "$value" ] || return 0
    for seen in "${REDACTION_VALUES[@]:-}"; do
        if [ "$seen" = "$value" ]; then
            return 0
        fi
    done
    REDACTION_VALUES+=("$value")
}

shell_quote() {
    local quoted

    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

format_shell_command() {
    local arg quoted formatted=""

    for arg in "$@"; do
        quoted="$(shell_quote "$arg")"
        if [ -n "$formatted" ]; then
            formatted+=" "
        fi
        formatted+="$quoted"
    done

    printf '%s\n' "$formatted"
}

collect_redaction_values_from_env_file() {
    local env_file="$1"
    local line parse_status key value

    [ -n "$env_file" ] || return 0
    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -ne 0 ]; then
            continue
        fi

        key="$ENV_ASSIGNMENT_KEY"
        value="$ENV_ASSIGNMENT_VALUE"
        case "$key" in
            AWS_SECRET_ACCESS_KEY|CLOUDFLARE_API_TOKEN|STRIPE_SECRET_KEY|STRIPE_TEST_SECRET_KEY|STRIPE_WEBHOOK_SECRET)
                add_redaction_value "$value"
                ;;
            CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_*)
                add_redaction_value "$value"
                ;;
        esac
    done < "$env_file"
}

redact_text() {
    local text="$1"
    local redacted_text

    if [ "${#REDACTION_VALUES[@]}" -eq 0 ]; then
        printf '%s' "$text"
        return 0
    fi

    redacted_text="$(
        {
            printf '%s\0' "$text"
            printf '%s\0' "${REDACTION_VALUES[@]}"
        } | python3 -c '
import sys

chunks = sys.stdin.buffer.read().split(b"\0")
value = chunks[0].decode("utf-8", errors="ignore") if chunks else ""
for raw_secret in chunks[1:]:
    if not raw_secret:
        continue
    secret = raw_secret.decode("utf-8", errors="ignore")
    if secret:
        value = value.replace(secret, "REDACTED")
print(value, end="")
'
    )"
    printf '%s' "$redacted_text"
}

redact_file_in_place() {
    local path="$1"
    local redacted_payload

    [ -f "$path" ] || return 0
    if [ "${#REDACTION_VALUES[@]}" -eq 0 ]; then
        return 0
    fi

    redacted_payload="$(
        printf '%s\0' "${REDACTION_VALUES[@]}" | python3 -c '
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = path.read_text(encoding="utf-8", errors="ignore")
for raw_secret in sys.stdin.buffer.read().split(b"\0"):
    if not raw_secret:
        continue
    secret = raw_secret.decode("utf-8", errors="ignore")
    if secret:
        payload = payload.replace(secret, "REDACTED")
print(payload, end="")
' "$path"
    )"
    printf '%s' "$redacted_payload" > "$path"
}

json_array_from_rows() {
    local rows_jsonl="$1"
    ROWS_JSONL="$rows_jsonl" python3 - <<'PY'
import json
import os

rows = []
for raw_line in os.environ.get("ROWS_JSONL", "").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    try:
        payload = json.loads(line)
    except Exception:
        continue
    rows.append(payload)

print(json.dumps(rows))
PY
}

append_check_row() {
    local lane="$1"
    local name="$2"
    local status="$3"
    local exit_code="$4"
    local detail="$5"
    local artifact_path="$6"
    local name_json status_json detail_json artifact_json row_json

    name_json="$(validation_json_escape "$name")"
    status_json="$(validation_json_escape "$status")"
    detail_json="$(validation_json_escape "$detail")"
    artifact_json="$(validation_json_escape "$artifact_path")"
    row_json="{\"name\":${name_json},\"status\":${status_json},\"exit_code\":${exit_code},\"detail\":${detail_json},\"artifact_path\":${artifact_json}}"

    if [ "$lane" = "credentialed_checks" ]; then
        CRED_CHECK_ROWS_JSONL+="$row_json"$'\n'
    else
        CHECK_ROWS_JSONL+="$row_json"$'\n'
    fi

    CHECK_COUNT=$((CHECK_COUNT + 1))
    if [ "$status" = "fail" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$status" = "blocked" ]; then
        BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
    fi
}

append_external_blocker() {
    local blocker="$1"
    local owner="$2"
    local command="$3"
    local blocker_json owner_json command_json row_json

    blocker_json="$(validation_json_escape "$blocker")"
    owner_json="$(validation_json_escape "$owner")"
    command_json="$(validation_json_escape "$command")"
    row_json="{\"blocker\":${blocker_json},\"owner\":${owner_json},\"command\":${command_json}}"

    BLOCKER_ROWS_JSONL+="$row_json"$'\n'
    BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
}

derive_overall_verdict() {
    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf 'fail\n'
        return 0
    fi
    if [ "$BLOCKER_COUNT" -gt 0 ]; then
        printf 'blocked\n'
        return 0
    fi
    if [ "$CHECK_COUNT" -gt 0 ]; then
        printf 'pass\n'
        return 0
    fi
    printf 'blocked\n'
}

validate_json_payload() {
    local payload="$1"
    python3 - "$payload" <<'PY' >/dev/null
import json
import sys

json.loads(sys.argv[1])
PY
}

assemble_summary_json() {
    local checks_json cred_checks_json blockers_json overall_verdict
    local run_id_json started_at_json env_json domain_json artifact_dir_json overall_verdict_json

    checks_json="$(json_array_from_rows "$CHECK_ROWS_JSONL")"
    cred_checks_json="$(json_array_from_rows "$CRED_CHECK_ROWS_JSONL")"
    blockers_json="$(json_array_from_rows "$BLOCKER_ROWS_JSONL")"
    overall_verdict="$(derive_overall_verdict)"

    run_id_json="$(validation_json_escape "$RUN_ID")"
    started_at_json="$(validation_json_escape "$STARTED_AT")"
    env_json="$(validation_json_escape "$LIVE_E2E_ENV")"
    domain_json="$(validation_json_escape "$LIVE_E2E_DOMAIN")"
    artifact_dir_json="$(validation_json_escape "$RUN_DIR")"
    overall_verdict_json="$(validation_json_escape "$overall_verdict")"

    printf '{"run_id":%s,"started_at":%s,"env":%s,"domain":%s,"artifact_dir":%s,"overall_verdict":%s,"checks":%s,"credentialed_checks":%s,"external_blockers":%s}\n' \
        "$run_id_json" \
        "$started_at_json" \
        "$env_json" \
        "$domain_json" \
        "$artifact_dir_json" \
        "$overall_verdict_json" \
        "$checks_json" \
        "$cred_checks_json" \
        "$blockers_json"
}

capture_owner_logs() {
    local stdout_log="$1"
    local stderr_log="$2"
    shift 2

    if "$@" >"$stdout_log" 2>"$stderr_log"; then
        return 0
    else
        return $?
    fi
}

run_runtime_smoke_check() {
    local logs_dir="$1"
    local runtime_stdout_log="$logs_dir/runtime_smoke.stdout.log"
    local runtime_stderr_log="$logs_dir/runtime_smoke.stderr.log"
    local runtime_combined_log="$logs_dir/runtime_smoke.log"
    local exit_code=0
    if [ "${#LIVE_E2E_RUNTIME_OWNER_ARGS[@]}" -gt 0 ]; then
        if capture_owner_logs \
            "$runtime_stdout_log" \
            "$runtime_stderr_log" \
            bash \
            "$RUNTIME_SMOKE_SCRIPT" \
            --env "$LIVE_E2E_ENV" \
            --domain "$LIVE_E2E_DOMAIN" \
            --env-file "$LIVE_E2E_ENV_FILE" \
            --ami-id "$LIVE_E2E_AMI_ID" \
            "${LIVE_E2E_RUNTIME_OWNER_ARGS[@]}"; then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if capture_owner_logs \
            "$runtime_stdout_log" \
            "$runtime_stderr_log" \
            bash \
            "$RUNTIME_SMOKE_SCRIPT" \
            --env "$LIVE_E2E_ENV" \
            --domain "$LIVE_E2E_DOMAIN" \
            --env-file "$LIVE_E2E_ENV_FILE" \
            --ami-id "$LIVE_E2E_AMI_ID"; then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    cat "$runtime_stdout_log" "$runtime_stderr_log" > "$runtime_combined_log"
    redact_file_in_place "$runtime_stdout_log"
    redact_file_in_place "$runtime_stderr_log"
    redact_file_in_place "$runtime_combined_log"

    local detail_suffix=""
    if [ "${#REDACTION_VALUES[@]}" -gt 0 ]; then
        detail_suffix="; sensitive values are scrubbed as REDACTED"
    fi

    if [ "$exit_code" -eq 0 ]; then
        append_check_row "checks" "runtime_smoke" "pass" "0" "runtime smoke owner passed${detail_suffix}" "$runtime_combined_log"
    else
        append_check_row "checks" "runtime_smoke" "fail" "$exit_code" "runtime smoke owner failed; inspect captured logs${detail_suffix}" "$runtime_combined_log"
        append_external_blocker \
            "runtime_smoke_owner_failed" \
            "runtime_smoke" \
            "$(format_shell_command \
                "$RUNTIME_SMOKE_SCRIPT" \
                --env "$LIVE_E2E_ENV" \
                --domain "$LIVE_E2E_DOMAIN" \
                --env-file "$LIVE_E2E_ENV_FILE" \
                --ami-id "$LIVE_E2E_AMI_ID")"
    fi

    RUNTIME_SMOKE_EXIT_CODE="$exit_code"
}

append_blocked_billing_row() {
    local blocker="$1"
    local detail="$2"
    local command="$3"
    local blocked_detail

    blocked_detail="missing credentialed billing proof: $detail"

    append_check_row "credentialed_checks" "billing_rehearsal" "blocked" "0" "$blocked_detail" ""
    append_external_blocker "$blocker" "caller" "$command"
}

run_billing_rehearsal_check() {
    local logs_dir="$1"
    local billing_stdout_log="$logs_dir/billing_rehearsal.stdout.log"
    local billing_stderr_log="$logs_dir/billing_rehearsal.stderr.log"
    local billing_combined_log="$logs_dir/billing_rehearsal.log"
    local exit_code=0

    if capture_owner_logs \
        "$billing_stdout_log" \
        "$billing_stderr_log" \
        "$BILLING_REHEARSAL_SCRIPT" \
        --env-file "$LIVE_E2E_ENV_FILE" \
        --month "$LIVE_E2E_BILLING_MONTH" \
        --confirm-live-mutation; then
        exit_code=0
    else
        exit_code=$?
    fi

    cat "$billing_stdout_log" "$billing_stderr_log" > "$billing_combined_log"
    redact_file_in_place "$billing_stdout_log"
    redact_file_in_place "$billing_stderr_log"
    redact_file_in_place "$billing_combined_log"

    local detail_suffix=""
    if [ "${#REDACTION_VALUES[@]}" -gt 0 ]; then
        detail_suffix="; sensitive values are scrubbed as REDACTED"
    fi

    if [ "$exit_code" -eq 0 ]; then
        append_check_row "credentialed_checks" "billing_rehearsal" "pass" "0" "billing rehearsal owner passed${detail_suffix}" "$billing_combined_log"
    else
        append_check_row "credentialed_checks" "billing_rehearsal" "fail" "$exit_code" "billing rehearsal owner failed; inspect captured logs${detail_suffix}" "$billing_combined_log"
        append_external_blocker \
            "billing_rehearsal_owner_failed" \
            "billing_rehearsal" \
            "$(format_shell_command \
                "$BILLING_REHEARSAL_SCRIPT" \
                --env-file "$LIVE_E2E_ENV_FILE" \
                --month "$LIVE_E2E_BILLING_MONTH" \
                --confirm-live-mutation)"
    fi

    BILLING_REHEARSAL_EXIT_CODE="$exit_code"
}

run_credentialed_billing_lane_if_requested() {
    local logs_dir="$1"

    if [ "$LIVE_E2E_RUN_BILLING_REHEARSAL" -ne 1 ]; then
        return 0
    fi

    if [ -z "$LIVE_E2E_ENV_FILE" ]; then
        append_blocked_billing_row \
            "billing_rehearsal_missing_env_file" \
            "--env-file is required when --run-billing-rehearsal is requested." \
            "rerun with --run-billing-rehearsal --env-file <path> --month <YYYY-MM> --confirm-live-mutation"
        return 0
    fi

    if [ -z "$LIVE_E2E_BILLING_MONTH" ]; then
        append_blocked_billing_row \
            "billing_rehearsal_missing_month" \
            "--month is required when --run-billing-rehearsal is requested." \
            "rerun with --run-billing-rehearsal --env-file <path> --month <YYYY-MM> --confirm-live-mutation"
        return 0
    fi

    if [ "$LIVE_E2E_CONFIRM_LIVE_MUTATION" -ne 1 ]; then
        append_blocked_billing_row \
            "billing_rehearsal_missing_confirmation" \
            "--confirm-live-mutation is required when --run-billing-rehearsal is requested." \
            "rerun with --run-billing-rehearsal --env-file <path> --month <YYYY-MM> --confirm-live-mutation"
        return 0
    fi

    run_billing_rehearsal_check "$logs_dir"
}

emit_summary_json() {
    local summary_json
    summary_json="$(assemble_summary_json)"
    summary_json="$(redact_text "$summary_json")"
    validate_json_payload "$summary_json"
    printf '%s\n' "$summary_json" > "$SUMMARY_PATH"
    printf '%s\n' "$summary_json"
}

main() {
    parse_args "$@" || return 2

    if [ "$SHOW_HELP" -eq 1 ]; then
        print_usage
        return 0
    fi

    validate_required_args || return 2

    RUN_ID="$(create_run_id)"
    STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    ensure_artifact_root "$LIVE_E2E_ARTIFACT_ROOT" || return 1
    RUN_DIR="$(create_run_dir "$LIVE_E2E_ARTIFACT_ROOT" "$RUN_ID")"
    LOGS_DIR="$(logs_dir_for_run_dir "$RUN_DIR")"
    mkdir -p "$LOGS_DIR"
    SUMMARY_PATH="$(summary_path_for_run_dir "$RUN_DIR")"

    collect_redaction_values_from_env_file "$LIVE_E2E_ENV_FILE"

    local runtime_preconditions_complete=1
    if [ -z "$LIVE_E2E_ENV_FILE" ]; then
        runtime_preconditions_complete=0
        append_external_blocker "missing_env_file" "caller" "rerun with --env-file <path>"
    fi
    if [ -z "$LIVE_E2E_AMI_ID" ]; then
        runtime_preconditions_complete=0
        append_external_blocker "missing_ami_id" "caller" "rerun with --ami-id <ami-id>"
    fi

    if [ "$runtime_preconditions_complete" -eq 1 ]; then
        run_runtime_smoke_check "$LOGS_DIR"
    fi

    run_credentialed_billing_lane_if_requested "$LOGS_DIR"

    emit_summary_json

    if [ "$FAIL_COUNT" -gt 0 ]; then
        if [ "$RUNTIME_SMOKE_EXIT_CODE" -ne 0 ]; then
            return "$RUNTIME_SMOKE_EXIT_CODE"
        fi
        if [ "$BILLING_REHEARSAL_EXIT_CODE" -ne 0 ]; then
            return "$BILLING_REHEARSAL_EXIT_CODE"
        fi
        return 1
    fi

    return 0
}

main "$@"
