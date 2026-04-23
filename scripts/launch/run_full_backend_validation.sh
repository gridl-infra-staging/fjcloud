#!/usr/bin/env bash
set -euo pipefail
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [ "$SCRIPT_DIR" = "$SCRIPT_PATH" ]; then
    SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/live_gate.sh"
source "$REPO_ROOT/scripts/lib/stripe_checks.sh"
source "$REPO_ROOT/scripts/lib/env.sh"
CARGO_BIN="${FULL_VALIDATION_CARGO_BIN:-cargo}"
BACKEND_GATE_SCRIPT="${FULL_VALIDATION_BACKEND_GATE_SCRIPT:-$REPO_ROOT/scripts/launch/backend_launch_gate.sh}"
LOCAL_SIGNOFF_SCRIPT="${FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT:-$REPO_ROOT/scripts/local-signoff.sh}"
SES_READINESS_SCRIPT="${FULL_VALIDATION_SES_READINESS_SCRIPT:-$REPO_ROOT/scripts/validate_ses_readiness.sh}"
STAGING_BILLING_REHEARSAL_SCRIPT="${FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT:-$REPO_ROOT/scripts/staging_billing_rehearsal.sh}"
BROWSER_PREFLIGHT_SCRIPT="${FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT:-$REPO_ROOT/scripts/e2e-preflight.sh}"
TERRAFORM_STAGE7_STATIC_SCRIPT="${FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT:-$REPO_ROOT/ops/terraform/tests_stage7_static.sh}"
TERRAFORM_STAGE8_STATIC_SCRIPT="${FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT:-$REPO_ROOT/ops/terraform/tests_stage8_static.sh}"
TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="${FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT:-$REPO_ROOT/ops/terraform/tests_stage7_runtime_smoke.sh}"
PLAYWRIGHT_BIN="${FULL_VALIDATION_PLAYWRIGHT_BIN:-npx}"
PLAYWRIGHT_WEB_DIR="${FULL_VALIDATION_PLAYWRIGHT_WEB_DIR:-$REPO_ROOT/web}"
SHA_OVERRIDE=""
MODE="live"
ARTIFACT_DIR=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
STAGING_SMOKE_AMI_ID=""
EXPLICIT_MODE=""
RESOLVED_SHA=""
OVERALL_FAILED=0
READY="true"
PRE_FLIGHT_FAILURES=()
STEP_NAMES=()
STEP_STATUSES=()
STEP_REASONS=()
STEP_ELAPSED_MS=()
STEP_COMMAND=()
print_usage() {
    cat <<'USAGE'
Usage:
  run_full_backend_validation.sh [--dry-run] [--sha=<GIT_SHA>]
  run_full_backend_validation.sh --paid-beta-rc [--sha=<GIT_SHA>] [--artifact-dir=<dir>] [--credential-env-file=<path>] [--billing-month=<YYYY-MM>] [--staging-smoke-ami-id=<ami-id>]
  run_full_backend_validation.sh --help
Options:
  --dry-run                      Run in dry-run mode (stubs external dependency checks via backend gate DRY_RUN=1)
  --paid-beta-rc                 Run paid beta RC readiness mode with required delegated proofs
  --sha=<40-char-sha>            Commit SHA to validate in backend launch gate
  --artifact-dir=<dir>           Artifact directory used for delegated launch evidence outputs
  --credential-env-file=<path>   Optional credentials env file (KEY=value) for RC delegated proof inputs
  --billing-month=<YYYY-MM>      Billing month for RC staging billing rehearsal
  --staging-smoke-ami-id=<ami-id>
                                 AMI ID opt-in input for RC staging runtime smoke proof
  --help                         Show this help text
USAGE
}
append_step() {
    local name="$1"
    local status="$2"
    local reason="$3"
    local elapsed_ms="$4"
    STEP_NAMES+=("$name")
    STEP_STATUSES+=("$status")
    STEP_REASONS+=("$reason")
    STEP_ELAPSED_MS+=("$elapsed_ms")
}
is_valid_sha() {
    local sha="$1"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}
is_valid_billing_month() {
    local billing_month="$1"
    [[ "$billing_month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]
}
is_valid_ami_id() {
    local ami_id="$1"
    [[ "$ami_id" =~ ^ami-[0-9a-f]{8}([0-9a-f]{9})?$ ]]
}
DELEGATED_JSON_RESULT=""
DELEGATED_JSON_CLASSIFICATION=""
parse_delegated_billing_summary() {
    local json_body="$1"
    DELEGATED_JSON_RESULT=""
    DELEGATED_JSON_CLASSIFICATION=""
    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    local parsed_result="" parsed_classification="" parsed_line="" parsed_index=0
    while IFS= read -r parsed_line; do
        if [ "$parsed_index" -eq 0 ]; then
            parsed_result="$parsed_line"
        elif [ "$parsed_index" -eq 1 ]; then
            parsed_classification="$parsed_line"
        fi
        parsed_index=$((parsed_index + 1))
    done < <(
        python3 - "$json_body" <<'PY' 2>/dev/null || true
import json
import sys
body = sys.argv[1]
try:
    payload = json.loads(body)
except Exception:
    print("")
    print("")
    raise SystemExit(0)
result = payload.get("result", "")
classification = payload.get("classification", "")
print("" if result is None else str(result))
print("" if classification is None else str(classification))
PY
    )
    DELEGATED_JSON_RESULT="$parsed_result"
    DELEGATED_JSON_CLASSIFICATION="$parsed_classification"
}
resolve_sha() {
    if [ -n "$SHA_OVERRIDE" ]; then
        printf '%s\n' "$SHA_OVERRIDE"
        return 0
    fi
    local resolved
    if resolved="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" && is_valid_sha "$resolved"; then
        printf '%s\n' "$resolved"
        return 0
    fi
    return 1
}
emit_result_json() {
    local verdict="$1"
    local mode="$2"
    local start_ms="$3"
    local ready="$4"
    local end_ms total_elapsed
    end_ms="$(_ms_now)"
    total_elapsed=$((end_ms - start_ms))
    local names_encoded statuses_encoded reasons_encoded elapsed_encoded preflight_encoded=""
    names_encoded="$(printf '%s\x1f' "${STEP_NAMES[@]:-}")"
    statuses_encoded="$(printf '%s\x1f' "${STEP_STATUSES[@]:-}")"
    reasons_encoded="$(printf '%s\x1f' "${STEP_REASONS[@]:-}")"
    elapsed_encoded="$(printf '%s\x1f' "${STEP_ELAPSED_MS[@]:-}")"
    if [ "${#PRE_FLIGHT_FAILURES[@]}" -gt 0 ]; then
        preflight_encoded="$(printf '%s\x1f' "${PRE_FLIGHT_FAILURES[@]}")"
    fi
    NAMES="$names_encoded" \
    STATUSES="$statuses_encoded" \
    REASONS="$reasons_encoded" \
    ELAPSED="$elapsed_encoded" \
    PREFLIGHT="$preflight_encoded" \
    VERDICT="$verdict" \
    MODE="$mode" \
    TOTAL_ELAPSED="$total_elapsed" \
    READY="$ready" \
    python3 -c '
import json
import os
from datetime import datetime, timezone
def decode(key):
    raw = os.environ.get(key, "")
    if raw == "":
        return []
    parts = raw.split("\x1f")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts
names = decode("NAMES")
statuses = decode("STATUSES")
reasons = decode("REASONS")
elapsed = decode("ELAPSED")
preflight_failures = decode("PREFLIGHT")
steps = []
for idx, name in enumerate(names):
    status = statuses[idx] if idx < len(statuses) else "fail"
    reason = reasons[idx] if idx < len(reasons) else ""
    elapsed_raw = elapsed[idx] if idx < len(elapsed) else "0"
    try:
        elapsed_ms = int(elapsed_raw)
    except Exception:
        elapsed_ms = 0
    steps.append({
        "name": name,
        "status": status,
        "reason": reason,
        "elapsed_ms": elapsed_ms,
    })
ts = datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
obj = {
    "elapsed_ms": int(os.environ.get("TOTAL_ELAPSED", "0")),
    "mode": os.environ.get("MODE", "live"),
    "ready": os.environ.get("READY", "false").lower() == "true",
    "steps": steps,
    "timestamp": ts,
    "verdict": os.environ.get("VERDICT", "fail"),
}
if preflight_failures:
    obj["preflight_failures"] = preflight_failures
print(json.dumps(obj, sort_keys=True))
'
}
run_preflight() {
    PRE_FLIGHT_FAILURES=()
    local stripe_secret_key=""
    if ! stripe_secret_key="$(resolve_stripe_secret_key)"; then
        PRE_FLIGHT_FAILURES+=("missing STRIPE_SECRET_KEY")
    fi
    if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
        PRE_FLIGHT_FAILURES+=("missing STRIPE_WEBHOOK_SECRET")
    fi
    if [ -z "${DATABASE_URL:-}" ] && [ -z "${INTEGRATION_DB_URL:-}" ]; then
        PRE_FLIGHT_FAILURES+=("missing DATABASE_URL or INTEGRATION_DB_URL")
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        PRE_FLIGHT_FAILURES+=("missing python3 in PATH")
    fi
    if ! command -v "$CARGO_BIN" >/dev/null 2>&1; then
        PRE_FLIGHT_FAILURES+=("missing cargo in PATH")
    fi
    if ! resolve_sha >/dev/null 2>&1; then
        PRE_FLIGHT_FAILURES+=("missing git SHA (pass --sha=<sha> or ensure git rev-parse HEAD works)")
    fi
    if [ "${#PRE_FLIGHT_FAILURES[@]}" -ne 0 ]; then
        return 1
    fi
    return 0
}
run_step_cargo_tests() {
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local exit_code=0
    (
        cd "$REPO_ROOT/infra"
        "$CARGO_BIN" test --workspace
    ) >/dev/null 2>&1 || exit_code=$?
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    else
        status="fail"
        reason="cargo test --workspace failed"
    fi
    append_step "cargo_workspace_tests" "$status" "$reason" "$elapsed"
    return "$exit_code"
}
ensure_rc_artifact_dir() {
    if [ -n "$ARTIFACT_DIR" ]; then
        mkdir -p "$ARTIFACT_DIR"
        return 0
    fi
    ARTIFACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-paid-beta-rc-XXXXXX")"
}
read_env_value_from_file() {
    local env_file="$1"
    local key="$2"
    local line parse_status
    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if [ "$ENV_ASSIGNMENT_KEY" = "$key" ]; then
                printf '%s\n' "$ENV_ASSIGNMENT_VALUE"
                return 0
            fi
            continue
        fi
        if [ "$parse_status" -eq 2 ]; then
            continue
        fi
        return 2
    done < "$env_file"
    return 1
}
resolve_credential_value() {
    local key="$1"
    local explicit_value="${!key:-}"
    if [ -n "$explicit_value" ]; then
        printf '%s\n' "$explicit_value"
        return 0
    fi
    if [ -z "$CREDENTIAL_ENV_FILE" ]; then
        return 1
    fi
    if [ ! -f "$CREDENTIAL_ENV_FILE" ] || [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
        return 3
    fi
    local value="" value_status=0
    value="$(read_env_value_from_file "$CREDENTIAL_ENV_FILE" "$key")" || value_status=$?
    if [ "$value_status" -eq 2 ]; then
        return 2
    fi
    if [ "$value_status" -eq 0 ] && [ -n "$value" ]; then
        printf '%s\n' "$value"
        return 0
    fi
    return 1
}
run_step_local_signoff() {
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local exit_code=0
    bash "$LOCAL_SIGNOFF_SCRIPT" >/dev/null 2>&1 || exit_code=$?
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    else
        status="fail"
        reason="local_signoff_failed"
    fi
    append_step "local_signoff" "$status" "$reason" "$elapsed"
    return "$exit_code"
}
run_step_ses_readiness() {
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local ses_identity="" ses_region=""
    local ses_identity_status=0 ses_region_status=0
    local shell_ses_identity="${SES_FROM_ADDRESS:-}"
    ses_identity="$(resolve_credential_value "SES_FROM_ADDRESS")" || ses_identity_status=$?
    if [ "$ses_identity_status" -ne 0 ]; then
        status="blocked"
        case "$ses_identity_status" in
            2)
                reason="credentialed_env_file_parse_failed"
                ;;
            3)
                reason="credentialed_env_file_missing"
                ;;
            *)
                reason="credentialed_ses_identity_missing"
                ;;
        esac
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "ses_readiness" "$status" "$reason" "$elapsed"
        return 2
    fi
    ses_region="$(resolve_credential_value "SES_REGION")" || ses_region_status=$?
    if [ "$ses_region_status" -eq 2 ]; then
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "ses_readiness" "blocked" "credentialed_env_file_parse_failed" "$elapsed"
        return 2
    fi
    if [ "$ses_region_status" -eq 3 ]; then
        if [ -n "$shell_ses_identity" ]; then
            # SES region is optional for delegated readiness; missing env file
            # must not block when identity is already resolved from the shell.
            ses_region_status=1
            ses_region=""
        else
            end_ms="$(_ms_now)"
            elapsed=$((end_ms - start_ms))
            append_step "ses_readiness" "blocked" "credentialed_env_file_missing" "$elapsed"
            return 2
        fi
    fi
    local exit_code=0
    if [ "$ses_region_status" -eq 0 ] && [ -n "$ses_region" ]; then
        bash "$SES_READINESS_SCRIPT" --identity "$ses_identity" --region "$ses_region" >/dev/null 2>&1 || exit_code=$?
    else
        bash "$SES_READINESS_SCRIPT" --identity "$ses_identity" >/dev/null 2>&1 || exit_code=$?
    fi
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    else
        status="fail"
        reason="ses_readiness_failed"
    fi
    append_step "ses_readiness" "$status" "$reason" "$elapsed"
    return "$exit_code"
}
run_step_staging_billing_rehearsal() {
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    if [ -z "$CREDENTIAL_ENV_FILE" ] || [ ! -f "$CREDENTIAL_ENV_FILE" ] || [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "staging_billing_rehearsal" "blocked" "credentialed_billing_env_file_missing" "$elapsed"
        return 2
    fi
    if [ -z "$BILLING_MONTH" ]; then
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "staging_billing_rehearsal" "blocked" "credentialed_billing_month_missing" "$elapsed"
        return 2
    fi
    local output="" exit_code=0
    output="$(bash "$STAGING_BILLING_REHEARSAL_SCRIPT" \
        --env-file "$CREDENTIAL_ENV_FILE" \
        --month "$BILLING_MONTH" \
        --confirm-live-mutation 2>/dev/null)" || exit_code=$?
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    parse_delegated_billing_summary "$output"
    local delegated_result delegated_classification
    delegated_result="$DELEGATED_JSON_RESULT"
    delegated_classification="$DELEGATED_JSON_CLASSIFICATION"
    if [ "$delegated_result" = "blocked" ]; then
        status="blocked"
        reason="$delegated_classification"
        if [ -z "$reason" ]; then
            reason="staging_billing_rehearsal_blocked"
        fi
    elif [ "$delegated_result" = "failed" ]; then
        status="fail"
        reason="$delegated_classification"
        if [ -z "$reason" ]; then
            reason="staging_billing_rehearsal_failed"
        fi
    elif [ "$delegated_result" = "passed" ] && [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    elif [ "$exit_code" -eq 0 ]; then
        # Keep backward compatibility for delegated owners that still signal pass via exit code only.
        status="pass"
        reason=""
    else
        status="fail"
        reason="staging_billing_rehearsal_output_invalid"
    fi
    append_step "staging_billing_rehearsal" "$status" "$reason" "$elapsed"
    if [ "$status" = "pass" ]; then
        return 0
    fi
    return 1
}
build_browser_preflight_command() {
    STEP_COMMAND=(bash "$BROWSER_PREFLIGHT_SCRIPT")
}
build_browser_auth_setup_command() {
    STEP_COMMAND=(
        "$PLAYWRIGHT_BIN" playwright test
        -c playwright.config.ts
        tests/fixtures/auth.setup.ts
        tests/fixtures/admin.auth.setup.ts
        --project=setup:user
        --project=setup:admin
        --reporter=line
    )
}
build_terraform_stage7_static_command() {
    STEP_COMMAND=(bash "$TERRAFORM_STAGE7_STATIC_SCRIPT")
}
build_terraform_stage8_static_command() {
    STEP_COMMAND=(bash "$TERRAFORM_STAGE8_STATIC_SCRIPT")
}
build_staging_runtime_smoke_command() {
    STEP_COMMAND=(
        bash "$TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT"
        --env-file "$CREDENTIAL_ENV_FILE"
        --ami-id "$STAGING_SMOKE_AMI_ID"
        --env staging
    )
}
run_delegated_command_step() {
    local step_name="$1"
    local fail_reason="$2"
    local working_dir="$3"
    shift 3
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local exit_code=0
    if [ -n "$working_dir" ]; then
        (
            cd "$working_dir"
            "$@"
        ) >/dev/null 2>&1 || exit_code=$?
    else
        "$@" >/dev/null 2>&1 || exit_code=$?
    fi
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    else
        status="fail"
        reason="$fail_reason"
    fi
    append_step "$step_name" "$status" "$reason" "$elapsed"
    return "$exit_code"
}
run_step_browser_preflight() {
    build_browser_preflight_command
    run_delegated_command_step "browser_preflight" "browser_preflight_failed" "" "${STEP_COMMAND[@]}"
}
run_step_browser_auth_setup() {
    build_browser_auth_setup_command
    run_delegated_command_step "browser_auth_setup" "browser_auth_setup_failed" "$PLAYWRIGHT_WEB_DIR" "${STEP_COMMAND[@]}"
}
run_step_terraform_static_guardrails() {
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local stage7_exit=0 stage8_exit=0
    build_terraform_stage7_static_command
    "${STEP_COMMAND[@]}" >/dev/null 2>&1 || stage7_exit=$?
    build_terraform_stage8_static_command
    "${STEP_COMMAND[@]}" >/dev/null 2>&1 || stage8_exit=$?
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    if [ "$stage7_exit" -eq 0 ] && [ "$stage8_exit" -eq 0 ]; then
        status="pass"
        reason=""
    else
        status="fail"
        if [ "$stage7_exit" -ne 0 ] && [ "$stage8_exit" -ne 0 ]; then
            reason="terraform_static_guardrails_failed"
        elif [ "$stage7_exit" -ne 0 ]; then
            reason="terraform_stage7_static_failed"
        else
            reason="terraform_stage8_static_failed"
        fi
    fi
    append_step "terraform_static_guardrails" "$status" "$reason" "$elapsed"
    if [ "$status" = "pass" ]; then
        return 0
    fi
    return 1
}
run_step_staging_runtime_smoke() {
    local start_ms end_ms elapsed
    start_ms="$(_ms_now)"
    if [ -z "$STAGING_SMOKE_AMI_ID" ] || [ -z "$CREDENTIAL_ENV_FILE" ] || [ ! -f "$CREDENTIAL_ENV_FILE" ] || [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "staging_runtime_smoke" "blocked" "credentialed_staging_smoke_inputs_missing" "$elapsed"
        return 2
    fi
    build_staging_runtime_smoke_command
    run_delegated_command_step "staging_runtime_smoke" "staging_runtime_smoke_failed" "" "${STEP_COMMAND[@]}"
}
backend_gate_reason_from_json() {
    local payload="$1"
    python3 -c '
import json,sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("backend launch gate returned invalid JSON")
    raise SystemExit(0)
if data.get("verdict") == "pass":
    print("")
else:
    gates = data.get("gates", [])
    if isinstance(gates, list):
        failures = []
        for gate in gates:
            if isinstance(gate, dict) and gate.get("status") == "fail":
                name = gate.get("name", "unknown")
                reason = gate.get("reason", "")
                failures.append(f"{name}: {reason}" if reason else str(name))
        if failures:
            print("; ".join(failures))
            raise SystemExit(0)
    print(str(data.get("reason", "backend launch gate failed")))
' <<< "$payload"
}
run_step_backend_launch_gate() {
    local sha="$1"
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local output=""
    local exit_code=0
    if [ "$MODE" = "dry_run" ]; then
        output="$(env DRY_RUN=1 bash "$BACKEND_GATE_SCRIPT" --sha="$sha")" || exit_code=$?
    elif [ "$MODE" = "paid_beta_rc" ]; then
        output="$(env LAUNCH_GATE_EVIDENCE_DIR="$ARTIFACT_DIR" COLLECT_EVIDENCE_DIR="$ARTIFACT_DIR" bash "$BACKEND_GATE_SCRIPT" --sha="$sha")" || exit_code=$?
    else
        output="$(bash "$BACKEND_GATE_SCRIPT" --sha="$sha")" || exit_code=$?
    fi
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    local verdict=""
    verdict="$(python3 -c 'import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(str(data.get("verdict","")))
except Exception:
    print("")
' <<< "$output")"
    if [ "$exit_code" -eq 0 ] && [ "$verdict" = "pass" ]; then
        status="pass"
        reason=""
    else
        status="fail"
        reason="$(backend_gate_reason_from_json "$output")"
        if [ -z "$reason" ]; then
            reason="backend launch gate failed"
        fi
    fi
    append_step "backend_launch_gate" "$status" "$reason" "$elapsed"
    if [ "$status" = "pass" ]; then
        return 0
    fi
    return 1
}
reset_run_state() {
    SHA_OVERRIDE=""
    MODE="live"
    ARTIFACT_DIR=""
    CREDENTIAL_ENV_FILE=""
    BILLING_MONTH=""
    STAGING_SMOKE_AMI_ID=""
    EXPLICIT_MODE=""
    RESOLVED_SHA=""
    OVERALL_FAILED=0
    READY="true"
    STEP_NAMES=()
    STEP_STATUSES=()
    STEP_REASONS=()
    STEP_ELAPSED_MS=()
    PRE_FLIGHT_FAILURES=()
}
parse_cli_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help)
                print_usage
                return 10
                ;;
            --dry-run)
                if [ -n "$EXPLICIT_MODE" ] && [ "$EXPLICIT_MODE" != "dry_run" ]; then
                    echo "ERROR: --dry-run cannot be combined with --paid-beta-rc" >&2
                    print_usage >&2
                    return 2
                fi
                EXPLICIT_MODE="dry_run"
                ;;
            --paid-beta-rc)
                if [ -n "$EXPLICIT_MODE" ] && [ "$EXPLICIT_MODE" != "paid_beta_rc" ]; then
                    echo "ERROR: --paid-beta-rc cannot be combined with --dry-run" >&2
                    print_usage >&2
                    return 2
                fi
                EXPLICIT_MODE="paid_beta_rc"
                ;;
            --sha=*)
                SHA_OVERRIDE="${arg#--sha=}"
                ;;
            --artifact-dir=*)
                ARTIFACT_DIR="${arg#--artifact-dir=}"
                ;;
            --credential-env-file=*)
                CREDENTIAL_ENV_FILE="${arg#--credential-env-file=}"
                ;;
            --billing-month=*)
                BILLING_MONTH="${arg#--billing-month=}"
                ;;
            --staging-smoke-ami-id=*)
                STAGING_SMOKE_AMI_ID="${arg#--staging-smoke-ami-id=}"
                ;;
            *)
                echo "ERROR: unknown argument '$arg'" >&2
                print_usage >&2
                return 2
                ;;
        esac
    done
    return 0
}
validate_cli_args() {
    if [ -n "$SHA_OVERRIDE" ] && ! is_valid_sha "$SHA_OVERRIDE"; then
        echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
        return 2
    fi
    if [ -n "$BILLING_MONTH" ] && ! is_valid_billing_month "$BILLING_MONTH"; then
        echo "ERROR: --billing-month must use YYYY-MM format with month 01-12" >&2
        return 2
    fi
    if [ -n "$STAGING_SMOKE_AMI_ID" ] && ! is_valid_ami_id "$STAGING_SMOKE_AMI_ID"; then
        echo "ERROR: --staging-smoke-ami-id must use AMI ID format (ami-xxxxxxxx or ami-xxxxxxxxxxxxxxxxx)" >&2
        return 2
    fi
    return 0
}
resolve_mode() {
    if [ -n "$EXPLICIT_MODE" ]; then
        MODE="$EXPLICIT_MODE"
        return
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        MODE="dry_run"
    fi
}
resolve_optional_sha() {
    if resolve_sha >/dev/null 2>&1; then
        resolve_sha
    else
        printf '\n'
    fi
}
prepare_mode_requirements() {
    local start_ms="$1"
    if [ "$MODE" = "live" ]; then
        if ! run_preflight; then
            emit_result_json "fail" "$MODE" "$start_ms" "false"
            return 1
        fi
        RESOLVED_SHA="$(resolve_sha)"
        return 0
    fi
    if [ "$MODE" = "paid_beta_rc" ]; then
        if [ -z "$RESOLVED_SHA" ]; then
            PRE_FLIGHT_FAILURES=("missing git SHA (pass --sha=<sha> or ensure git rev-parse HEAD works)")
            emit_result_json "fail" "$MODE" "$start_ms" "false"
            return 1
        fi
        if ! ensure_rc_artifact_dir; then
            PRE_FLIGHT_FAILURES=("unable to prepare --artifact-dir path")
            emit_result_json "fail" "$MODE" "$start_ms" "false"
            return 1
        fi
    fi
    return 0
}
execute_required_step() {
    local step_function="$1"
    shift
    if ! "$step_function" "$@"; then
        OVERALL_FAILED=1
        READY="false"
    fi
}
run_required_paid_beta_rc_steps() {
    execute_required_step run_step_local_signoff
    execute_required_step run_step_ses_readiness
    # Required credentialed proof: missing env/month is intentionally blocked,
    # and blocked must keep ready=false with a legacy-compatible fail verdict.
    execute_required_step run_step_staging_billing_rehearsal
    execute_required_step run_step_browser_preflight
    execute_required_step run_step_browser_auth_setup
    execute_required_step run_step_terraform_static_guardrails
    execute_required_step run_step_staging_runtime_smoke
}
emit_final_result() {
    local start_ms="$1"
    local verdict="pass"
    if [ "$OVERALL_FAILED" -ne 0 ]; then
        verdict="fail"
    fi
    emit_result_json "$verdict" "$MODE" "$start_ms" "$READY"
    if [ "$OVERALL_FAILED" -ne 0 ]; then
        return 1
    fi
    return 0
}
run_full_backend_validation() {
    local start_ms
    start_ms="$(_ms_now)"
    reset_run_state
    local parse_status
    parse_cli_args "$@" || parse_status=$?
    if [ "${parse_status:-0}" -eq 10 ]; then
        return 0
    fi
    if [ "${parse_status:-0}" -ne 0 ]; then
        return "$parse_status"
    fi
    validate_cli_args || return $?
    resolve_mode
    RESOLVED_SHA="$(resolve_optional_sha)"
    prepare_mode_requirements "$start_ms" || return 1
    execute_required_step run_step_cargo_tests
    execute_required_step run_step_backend_launch_gate "$RESOLVED_SHA"
    if [ "$MODE" = "paid_beta_rc" ]; then
        run_required_paid_beta_rc_steps
    fi
    emit_final_result "$start_ms"
}
if [[ "${__RUN_FULL_BACKEND_VALIDATION_SOURCED:-0}" != "1" ]]; then
    run_full_backend_validation "$@"
fi
