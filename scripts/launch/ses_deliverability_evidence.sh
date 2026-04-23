#!/usr/bin/env bash

set -euo pipefail

# Deliverability evidence artifacts can capture sensitive env and log content.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
READINESS_SCRIPT="$REPO_ROOT/scripts/validate_ses_readiness.sh"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/validation_json.sh
source "$REPO_ROOT/scripts/lib/validation_json.sh"

SES_EVIDENCE_ARTIFACT_ROOT=""
SES_EVIDENCE_ENV_FILE=""
SHOW_HELP=0

RUN_ID=""
STARTED_AT=""
RUN_DIR=""
SUMMARY_PATH=""
LOGS_DIR=""

SES_FROM_ADDRESS_RESOLVED=""
SES_REGION_RESOLVED=""
SES_TEST_RECIPIENT_RESOLVED=""

READINESS_PASSED=false
ACCOUNT_BASELINE_READY=false
ACCOUNT_STATUS="blocked"
ACCOUNT_DETAIL="Account readiness not evaluated."
ACCOUNT_SANDBOX=false
IDENTITY_STATUS="blocked"
IDENTITY_DETAIL="Identity readiness not evaluated."

RECIPIENT_STATUS="blocked"
RECIPIENT_DETAIL="Recipient preflight not evaluated."
RECIPIENT_SOURCE="missing"
RECIPIENT_VALUE=""
RECIPIENT_IS_SIMULATOR=false

SEND_ATTEMPT_STATUS="blocked"
SEND_ATTEMPT_DETAIL="Live-send seam not attempted."
SEND_ATTEMPT_EXIT_CODE=0
SEND_ATTEMPT_MARKER_FOUND=false

SUPPRESSION_STATUS="not_checked"
SUPPRESSION_DETAIL="Suppression status not checked unless explicit lookup is requested."

REDACTION_VALUES=()

print_usage() {
    cat <<'USAGE'
Usage:
  ses_deliverability_evidence.sh --artifact-dir <dir> [--env-file <path>]
  ses_deliverability_evidence.sh --help
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
        --artifact-dir|--env-file)
            if [ "$arg_count" -lt 2 ] || [ -z "$next_value" ] || [[ "$next_value" == --* ]]; then
                echo "ERROR: $token requires a value" >&2
                print_usage >&2
                return 2
            fi
            case "$token" in
                --artifact-dir)
                    SES_EVIDENCE_ARTIFACT_ROOT="$next_value"
                    ;;
                --env-file)
                    SES_EVIDENCE_ENV_FILE="$next_value"
                    ;;
            esac
            PARSE_CONSUMED=2
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
    if [ -z "$SES_EVIDENCE_ARTIFACT_ROOT" ]; then
        echo "ERROR: --artifact-dir is required" >&2
        print_usage >&2
        return 2
    fi
    if [ -n "$SES_EVIDENCE_ENV_FILE" ] && [ ! -f "$SES_EVIDENCE_ENV_FILE" ]; then
        echo "ERROR: --env-file not found: $SES_EVIDENCE_ENV_FILE" >&2
        return 2
    fi
}

create_run_id() {
    printf 'fjcloud_ses_deliverability_evidence_%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
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

collect_redaction_values_from_env_file() {
    local env_file="$1"
    local line parse_status

    [ -n "$env_file" ] || return 0
    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -ne 0 ]; then
            continue
        fi
        add_redaction_value "$ENV_ASSIGNMENT_VALUE"
    done < "$env_file"
}

collect_redaction_values_from_env() {
    add_redaction_value "${AWS_SECRET_ACCESS_KEY:-}"
    add_redaction_value "${AWS_SESSION_TOKEN:-}"
    add_redaction_value "${SES_FROM_ADDRESS_RESOLVED:-}"
    add_redaction_value "${SES_TEST_RECIPIENT_RESOLVED:-}"
}

redact_text() {
    local text="$1"
    local redacted_text

    redacted_text="$(
        {
            printf '%s\0' "$text"
            if [ "${#REDACTION_VALUES[@]}" -gt 0 ]; then
                printf '%s\0' "${REDACTION_VALUES[@]}"
            fi
        } | python3 -c '
import re
import sys

chunks = sys.stdin.buffer.read().split(b"\0")
payload = chunks[0].decode("utf-8", errors="ignore") if chunks else ""
for raw_secret in chunks[1:]:
    if not raw_secret:
        continue
    secret = raw_secret.decode("utf-8", errors="ignore")
    if secret:
        payload = payload.replace(secret, "REDACTED")

payload = re.sub(r"raw-body=.*?(?=\\\\n|\n|$)", "raw-body=REDACTED", payload)
print(payload, end="")
'
    )"
    printf '%s' "$redacted_text"
}

redact_file_in_place() {
    local path="$1"
    local redacted_payload

    [ -f "$path" ] || return 0
    redacted_payload="$(redact_text "$(cat "$path")")"
    printf '%s' "$redacted_payload" > "$path"
}

json_step_field() {
    local json_payload="$1"
    local step_name="$2"
    local field_name="$3"

    python3 - "$json_payload" "$step_name" "$field_name" <<'PY' || true
import json
import sys

payload = sys.argv[1]
step_name = sys.argv[2]
field_name = sys.argv[3]
try:
    body = json.loads(payload)
except Exception:
    print("")
    raise SystemExit(0)

for step in body.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field_name, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        elif value is None:
            print("")
        else:
            print(str(value))
        raise SystemExit(0)

print("")
PY
}

resolve_inputs() {
    SES_FROM_ADDRESS_RESOLVED="${SES_FROM_ADDRESS:-}"
    SES_REGION_RESOLVED="${SES_REGION:-}"
    SES_TEST_RECIPIENT_RESOLVED="${SES_TEST_RECIPIENT:-}"
}

delegate_readiness_check() {
    local readiness_stdout_log="$LOGS_DIR/readiness_stdout.json"
    local readiness_stderr_log="$LOGS_DIR/readiness_stderr.log"
    local readiness_artifact="$RUN_DIR/readiness_owner_output.json"
    local readiness_json
    local readiness_cmd

    if [ -z "$SES_FROM_ADDRESS_RESOLVED" ]; then
        ACCOUNT_STATUS="blocked"
        ACCOUNT_DETAIL="Missing SES_FROM_ADDRESS; sender/account readiness cannot be delegated."
        IDENTITY_STATUS="blocked"
        IDENTITY_DETAIL="Missing SES_FROM_ADDRESS; sender identity readiness is unproven."
        READINESS_PASSED=false
        return 0
    fi

    if [ -z "$SES_REGION_RESOLVED" ]; then
        ACCOUNT_STATUS="blocked"
        ACCOUNT_DETAIL="SES_REGION is missing; readiness delegation requires canonical SES region input."
        IDENTITY_STATUS="blocked"
        IDENTITY_DETAIL="SES_REGION is missing; sender identity readiness is unproven."
        READINESS_PASSED=false
        return 0
    fi

    readiness_cmd=(bash "$READINESS_SCRIPT" "--identity" "$SES_FROM_ADDRESS_RESOLVED" "--region" "$SES_REGION_RESOLVED")

    if AWS_PAGER="" "${readiness_cmd[@]}" >"$readiness_stdout_log" 2>"$readiness_stderr_log"; then
        READINESS_PASSED=true
    else
        READINESS_PASSED=false
    fi

    if [ -f "$readiness_stdout_log" ]; then
        cp "$readiness_stdout_log" "$readiness_artifact"
    fi
    redact_file_in_place "$readiness_stdout_log"
    redact_file_in_place "$readiness_stderr_log"
    redact_file_in_place "$readiness_artifact"

    readiness_json="$(cat "$readiness_artifact" 2>/dev/null || true)"
    if [ -z "$readiness_json" ]; then
        ACCOUNT_STATUS="blocked"
        ACCOUNT_DETAIL="Readiness owner produced no machine-readable output."
        IDENTITY_STATUS="blocked"
        IDENTITY_DETAIL="Readiness owner produced no identity verification evidence."
        return 0
    fi

    local get_account_pass sending_enabled_pass production_detail
    local identity_pass dkim_pass identity_detail dkim_detail
    get_account_pass="$(json_step_field "$readiness_json" "get_account" "passed")"
    sending_enabled_pass="$(json_step_field "$readiness_json" "sending_enabled" "passed")"
    production_detail="$(json_step_field "$readiness_json" "production_access" "detail")"
    identity_pass="$(json_step_field "$readiness_json" "identity_verified" "passed")"
    dkim_pass="$(json_step_field "$readiness_json" "dkim_verified" "passed")"
    identity_detail="$(json_step_field "$readiness_json" "identity_verified" "detail")"
    dkim_detail="$(json_step_field "$readiness_json" "dkim_verified" "detail")"

    if [[ "$production_detail" == *"ProductionAccessEnabled=false"* ]] || [[ "$production_detail" == *"sandbox"* ]]; then
        ACCOUNT_SANDBOX=true
    fi

    if [ "$get_account_pass" = "true" ] && [ "$sending_enabled_pass" = "true" ]; then
        ACCOUNT_BASELINE_READY=true
        if [ "$ACCOUNT_SANDBOX" = true ]; then
            ACCOUNT_STATUS="blocked"
            ACCOUNT_DETAIL="SES account remains in sandbox (${production_detail:-ProductionAccessEnabled=false}); production deliverability is blocked."
        else
            ACCOUNT_STATUS="pass"
            ACCOUNT_DETAIL="Readiness owner confirmed account sending readiness (${production_detail:-ProductionAccessEnabled=true})."
        fi
    else
        ACCOUNT_BASELINE_READY=false
        ACCOUNT_STATUS="blocked"
        ACCOUNT_DETAIL="Readiness owner did not prove account readiness (${production_detail:-account readiness failed})."
    fi

    if [ "$identity_pass" = "true" ] && [ "$dkim_pass" = "true" ]; then
        IDENTITY_STATUS="pass"
        IDENTITY_DETAIL="Readiness owner confirmed sender identity readiness (${identity_detail}; ${dkim_detail})."
    else
        IDENTITY_STATUS="blocked"
        IDENTITY_DETAIL="Readiness owner did not prove sender identity readiness (${identity_detail}; ${dkim_detail})."
    fi
}

is_mailbox_simulator_recipient() {
    local recipient="$1"
    [[ "$recipient" == *@simulator.amazonses.com ]]
}

derive_self_discovery_recipient() {
    local sender="$1"
    local sender_domain=""

    if [[ "$sender" == *"@"* ]]; then
        sender_domain="${sender#*@}"
    fi
    if [ -z "$sender_domain" ]; then
        printf '\n'
        return 0
    fi
    printf 'deliverability-self-check@%s\n' "$sender_domain"
}

verify_recipient_identity() {
    local recipient="$1"
    local verify_stdout_log="$LOGS_DIR/recipient_preflight_stdout.json"
    local verify_stderr_log="$LOGS_DIR/recipient_preflight_stderr.log"
    local verify_cmd=(aws sesv2 get-email-identity "--email-identity=$recipient" --output json --no-cli-pager)
    local verification_json verification_status

    if [ -n "$SES_REGION_RESOLVED" ]; then
        verify_cmd+=("--region=$SES_REGION_RESOLVED")
    fi

    if ! AWS_PAGER="" "${verify_cmd[@]}" >"$verify_stdout_log" 2>"$verify_stderr_log"; then
        redact_file_in_place "$verify_stdout_log"
        redact_file_in_place "$verify_stderr_log"
        return 1
    fi

    redact_file_in_place "$verify_stdout_log"
    redact_file_in_place "$verify_stderr_log"
    verification_json="$(cat "$verify_stdout_log" 2>/dev/null || true)"
    verification_status="$(validation_json_get_field "$verification_json" "VerificationStatus")"
    if [ "$verification_status" = "SUCCESS" ]; then
        return 0
    fi
    return 1
}

run_recipient_preflight() {
    local candidate_recipient=""

    if [ -n "$SES_TEST_RECIPIENT_RESOLVED" ]; then
        candidate_recipient="$SES_TEST_RECIPIENT_RESOLVED"
        RECIPIENT_SOURCE="explicit"
    else
        candidate_recipient="$(derive_self_discovery_recipient "$SES_FROM_ADDRESS_RESOLVED")"
        if [ -n "$candidate_recipient" ]; then
            RECIPIENT_SOURCE="self_discovery"
        else
            RECIPIENT_SOURCE="missing"
        fi
    fi

    if [ -z "$candidate_recipient" ]; then
        RECIPIENT_STATUS="blocked"
        RECIPIENT_DETAIL="No recipient supplied and no verified self-recipient candidate could be derived."
        return 0
    fi

    if [ -z "$SES_REGION_RESOLVED" ]; then
        RECIPIENT_STATUS="blocked"
        RECIPIENT_DETAIL="SES_REGION is missing; recipient preflight requires canonical SES region input."
        RECIPIENT_VALUE="$candidate_recipient"
        return 0
    fi

    RECIPIENT_VALUE="$candidate_recipient"
    if is_mailbox_simulator_recipient "$candidate_recipient"; then
        RECIPIENT_IS_SIMULATOR=true
        RECIPIENT_STATUS="pass"
        RECIPIENT_DETAIL="Recipient uses SES mailbox simulator; send evidence is allowed without inbox-receipt proof."
        return 0
    fi

    if [ "$candidate_recipient" = "$SES_FROM_ADDRESS_RESOLVED" ] && [ "$IDENTITY_STATUS" = "pass" ]; then
        RECIPIENT_STATUS="pass"
        RECIPIENT_DETAIL="Recipient matches sender identity already verified by readiness owner."
        return 0
    fi

    if verify_recipient_identity "$candidate_recipient"; then
        RECIPIENT_STATUS="pass"
        if [ "$RECIPIENT_SOURCE" = "self_discovery" ]; then
            RECIPIENT_DETAIL="Verified self-recipient discovery succeeded for recipient '${candidate_recipient}'."
        else
            RECIPIENT_DETAIL="Recipient identity '${candidate_recipient}' is verified."
        fi
    else
        RECIPIENT_STATUS="blocked"
        if [ "$ACCOUNT_SANDBOX" = true ]; then
            RECIPIENT_DETAIL="Recipient '${candidate_recipient}' is not verified for a sandbox account; sandbox recipient limits block live send."
        else
            RECIPIENT_DETAIL="Recipient '${candidate_recipient}' is not verified or cannot be resolved."
        fi
    fi
}

run_live_send_seam() {
    local cargo_stdout_log="$LOGS_DIR/cargo_live_send_stdout.log"
    local cargo_stderr_log="$LOGS_DIR/cargo_live_send_stderr.log"
    local cargo_output
    local cargo_cmd=(cargo test -p api --test email_test ses_live_smoke_sends_verification_email -- --ignored)

    if [ -z "$SES_REGION_RESOLVED" ]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="SES_REGION is missing; canonical live-send seam requires an explicit SES region."
        return 0
    fi
    if [ "$ACCOUNT_BASELINE_READY" != true ]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="Account readiness is blocked; live-send seam was not attempted."
        return 0
    fi
    if [ "$IDENTITY_STATUS" != "pass" ]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="Sender identity readiness is blocked; live-send seam was not attempted."
        return 0
    fi
    if [ "$RECIPIENT_STATUS" != "pass" ]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="Recipient preflight is blocked; live-send seam was not attempted."
        return 0
    fi
    if [ "$ACCOUNT_SANDBOX" = true ] && [ "$RECIPIENT_IS_SIMULATOR" != true ]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="SES account remains in sandbox and recipient is not a mailbox simulator; live-send seam was not attempted."
        return 0
    fi

    SEND_ATTEMPT_EXIT_CODE=0
    (
        cd "$REPO_ROOT/infra"
        SES_LIVE_TEST=1 \
        SES_FROM_ADDRESS="$SES_FROM_ADDRESS_RESOLVED" \
        SES_REGION="$SES_REGION_RESOLVED" \
        SES_TEST_RECIPIENT="$RECIPIENT_VALUE" \
        "${cargo_cmd[@]}"
    ) >"$cargo_stdout_log" 2>"$cargo_stderr_log" || SEND_ATTEMPT_EXIT_CODE=$?

    redact_file_in_place "$cargo_stdout_log"
    redact_file_in_place "$cargo_stderr_log"
    cargo_output="$(cat "$cargo_stdout_log" 2>/dev/null || true)$(printf '\n')$(cat "$cargo_stderr_log" 2>/dev/null || true)"

    if [[ "$cargo_output" == *"test ses_live_smoke_sends_verification_email ... ok"* ]]; then
        SEND_ATTEMPT_MARKER_FOUND=true
        SEND_ATTEMPT_STATUS="pass"
        SEND_ATTEMPT_DETAIL="Canonical live-send seam reported a positive named-test marker."
        return 0
    fi

    if [[ "$cargo_output" == *"SES_LIVE_TEST not set"* ]]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="Cargo output indicates the live smoke test was skipped."
        return 0
    fi
    if [[ "$cargo_output" == *"running 0 tests"* ]]; then
        SEND_ATTEMPT_STATUS="blocked"
        SEND_ATTEMPT_DETAIL="Cargo output reported running 0 tests; no live-send evidence was produced."
        return 0
    fi
    if [ "$SEND_ATTEMPT_EXIT_CODE" -ne 0 ]; then
        SEND_ATTEMPT_STATUS="fail"
        SEND_ATTEMPT_DETAIL="Canonical live-send seam exited non-zero (${SEND_ATTEMPT_EXIT_CODE})."
        return 0
    fi
    if [[ "$cargo_output" == *"test "* ]]; then
        SEND_ATTEMPT_STATUS="fail"
        SEND_ATTEMPT_DETAIL="Cargo output did not include a passing marker for ses_live_smoke_sends_verification_email."
        return 0
    fi
    SEND_ATTEMPT_STATUS="blocked"
    SEND_ATTEMPT_DETAIL="Cargo exited without a positive marker for the canonical live-send seam."
}

derive_overall_verdict() {
    if [ "$SEND_ATTEMPT_STATUS" = "fail" ]; then
        printf 'fail\n'
        return 0
    fi
    if [ "$ACCOUNT_STATUS" = "blocked" ] || [ "$IDENTITY_STATUS" = "blocked" ] || [ "$RECIPIENT_STATUS" = "blocked" ] || [ "$SEND_ATTEMPT_STATUS" = "blocked" ]; then
        printf 'blocked\n'
        return 0
    fi
    printf 'pass\n'
}

assemble_summary_json() {
    local overall_verdict="$1"

    RUN_ID="$RUN_ID" \
    STARTED_AT="$STARTED_AT" \
    RUN_DIR="$RUN_DIR" \
    OVERALL_VERDICT="$overall_verdict" \
    SES_FROM_ADDRESS_RESOLVED="$SES_FROM_ADDRESS_RESOLVED" \
    SES_REGION_RESOLVED="$SES_REGION_RESOLVED" \
    ACCOUNT_STATUS="$ACCOUNT_STATUS" \
    ACCOUNT_DETAIL="$ACCOUNT_DETAIL" \
    ACCOUNT_SANDBOX="$ACCOUNT_SANDBOX" \
    IDENTITY_STATUS="$IDENTITY_STATUS" \
    IDENTITY_DETAIL="$IDENTITY_DETAIL" \
    RECIPIENT_STATUS="$RECIPIENT_STATUS" \
    RECIPIENT_DETAIL="$RECIPIENT_DETAIL" \
    RECIPIENT_SOURCE="$RECIPIENT_SOURCE" \
    RECIPIENT_VALUE="$RECIPIENT_VALUE" \
    RECIPIENT_IS_SIMULATOR="$RECIPIENT_IS_SIMULATOR" \
    SEND_ATTEMPT_STATUS="$SEND_ATTEMPT_STATUS" \
    SEND_ATTEMPT_DETAIL="$SEND_ATTEMPT_DETAIL" \
    SEND_ATTEMPT_EXIT_CODE="$SEND_ATTEMPT_EXIT_CODE" \
    SEND_ATTEMPT_MARKER_FOUND="$SEND_ATTEMPT_MARKER_FOUND" \
    SUPPRESSION_STATUS="$SUPPRESSION_STATUS" \
    SUPPRESSION_DETAIL="$SUPPRESSION_DETAIL" \
    python3 - <<'PY'
import json
import os

summary = {
    "run_id": os.environ["RUN_ID"],
    "started_at": os.environ["STARTED_AT"],
    "artifact_dir": os.environ["RUN_DIR"],
    "overall_verdict": os.environ["OVERALL_VERDICT"],
    "sender": {
        "from_address": os.environ["SES_FROM_ADDRESS_RESOLVED"],
        "region": os.environ["SES_REGION_RESOLVED"],
    },
    "account_status": {
        "status": os.environ["ACCOUNT_STATUS"],
        "detail": os.environ["ACCOUNT_DETAIL"],
        "is_sandbox": os.environ["ACCOUNT_SANDBOX"] == "true",
    },
    "identity_status": {
        "status": os.environ["IDENTITY_STATUS"],
        "detail": os.environ["IDENTITY_DETAIL"],
    },
    "recipient_preflight": {
        "status": os.environ["RECIPIENT_STATUS"],
        "detail": os.environ["RECIPIENT_DETAIL"],
        "source": os.environ["RECIPIENT_SOURCE"],
        "recipient": os.environ["RECIPIENT_VALUE"],
        "is_mailbox_simulator": os.environ["RECIPIENT_IS_SIMULATOR"] == "true",
    },
    "send_attempt": {
        "status": os.environ["SEND_ATTEMPT_STATUS"],
        "detail": os.environ["SEND_ATTEMPT_DETAIL"],
        "exit_code": int(os.environ["SEND_ATTEMPT_EXIT_CODE"]),
        "named_test_marker_found": os.environ["SEND_ATTEMPT_MARKER_FOUND"] == "true",
        "command": "cd infra && cargo test -p api --test email_test ses_live_smoke_sends_verification_email -- --ignored",
    },
    "suppression_check": {
        "status": os.environ["SUPPRESSION_STATUS"],
        "detail": os.environ["SUPPRESSION_DETAIL"],
    },
    "deliverability_boundaries": {
        "spf": "unproven",
        "mail_from": "unproven",
        "bounce_complaint_handling": "unproven",
        "first_send_evidence": "unproven",
        "inbox_receipt_proof": "unproven",
        "notes": [
            "SPF evidence remains unproven by this wrapper.",
            "MAIL FROM alignment remains unproven by this wrapper.",
            "bounce/complaint handling remains unproven by this wrapper.",
            "first-send reputation evidence remains unproven by this wrapper.",
            "inbox-receipt proof remains unproven by this wrapper.",
        ],
    },
    "redaction": {
        "marker": "REDACTED",
        "detail": "Sensitive env values and full email bodies are REDACTED.",
    },
}

print(json.dumps(summary, separators=(",", ":")))
PY
}

emit_summary() {
    local summary_json="$1"
    local redacted_summary

    redacted_summary="$(redact_text "$summary_json")"
    printf '%s\n' "$redacted_summary" > "$SUMMARY_PATH"
    printf '%s\n' "$redacted_summary"
}

main() {
    parse_args "$@" || exit 2
    validate_required_args || exit 2
    if [ "$SHOW_HELP" -eq 1 ]; then
        print_usage
        exit 0
    fi

    if [ -n "$SES_EVIDENCE_ENV_FILE" ]; then
        load_env_file "$SES_EVIDENCE_ENV_FILE"
    fi
    resolve_inputs
    collect_redaction_values_from_env_file "$SES_EVIDENCE_ENV_FILE"
    collect_redaction_values_from_env

    ensure_artifact_root "$SES_EVIDENCE_ARTIFACT_ROOT"
    RUN_ID="$(create_run_id)"
    STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    RUN_DIR="$(create_run_dir "$SES_EVIDENCE_ARTIFACT_ROOT" "$RUN_ID")"
    SUMMARY_PATH="$(summary_path_for_run_dir "$RUN_DIR")"
    LOGS_DIR="$(logs_dir_for_run_dir "$RUN_DIR")"
    mkdir -p "$LOGS_DIR"

    delegate_readiness_check
    run_recipient_preflight
    run_live_send_seam

    local overall_verdict summary_json
    overall_verdict="$(derive_overall_verdict)"
    summary_json="$(assemble_summary_json "$overall_verdict")"
    emit_summary "$summary_json"

    if [ "$overall_verdict" = "fail" ]; then
        exit 1
    fi
    exit 0
}

main "$@"
