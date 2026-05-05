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
source "$REPO_ROOT/scripts/lib/full_backend_validation_cli.sh"
source "$REPO_ROOT/scripts/lib/full_backend_validation_json.sh"
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
OUTSIDE_AWS_HEALTH_SCRIPT="${FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT:-$REPO_ROOT/scripts/canary/outside_aws_health_check.sh}"
SES_INBOUND_ROUNDTRIP_SCRIPT="${FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT:-$REPO_ROOT/scripts/validate_inbound_email_roundtrip.sh}"
CANARY_CUSTOMER_LOOP_SCRIPT="${FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT:-$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh}"
SHA_OVERRIDE=""
MODE="live"
ARTIFACT_DIR=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
STAGING_SMOKE_AMI_ID=""
STAGING_ONLY=0
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
DELEGATED_SKIP_EXIT_CODE=3
STAGING_ONLY_PRODUCTION_SKIP_REASON="staging_only_production_surface"
CRITICAL_BROWSER_STEPS=("browser_preflight" "browser_auth_setup" "browser_signup_paid" "browser_portal_cancel")
print_usage() {
    cat <<'USAGE'
Usage:
  run_full_backend_validation.sh [--dry-run] [--sha=<GIT_SHA>]
  run_full_backend_validation.sh --paid-beta-rc [--staging-only] [--sha=<GIT_SHA>] [--artifact-dir=<dir>] [--credential-env-file=<path>] [--billing-month=<YYYY-MM>] [--staging-smoke-ami-id=<ami-id>]
  run_full_backend_validation.sh --help
Options:
  --dry-run                      Run in dry-run mode (stubs external dependency checks via backend gate DRY_RUN=1)
  --paid-beta-rc                 Run paid beta RC readiness mode with required delegated proofs
  --staging-only                 RC sub-mode: run staging proofs, soft-skip production-facing proofs
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
    local start_ms end_ms elapsed status reason log_path
    start_ms="$(_ms_now)"
    local exit_code=0
    log_path="$(_step_log_path cargo_workspace_tests)"
    # cargo test --workspace is the workspace smoke gate — it must NOT inherit
    # operator-supplied DATABASE_URL / INTEGRATION_DB_URL from the parent shell.
    # Reason: pg_customer_repo_test (and similar pg-bound tests) skips cleanly
    # when DATABASE_URL is unset, but panics with "connect to integration test
    # DB" when it IS set and unreachable. An operator running the RC from a
    # dev laptop typically hydrates DATABASE_URL=staging-internal-host (so the
    # backend_launch_gate's DB checks can run), and that staging host is not
    # reachable from outside the VPC — so pg tests panic on DNS resolve and
    # the workspace step false-fails. Tests that genuinely need a live DB are
    # opt-in via the paid-beta-rc rust steps below (admin_broadcast,
    # billing_health_last_activity, audit_timeline) which set their own env.
    # See test_cargo_workspace_step_does_not_inherit_db_url_from_parent_env.
    (
        cd "$REPO_ROOT/infra"
        unset DATABASE_URL INTEGRATION_DB_URL
        "$CARGO_BIN" test --workspace
    ) >"$log_path" 2>&1 || exit_code=$?
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
# Returns the absolute path to which a step's external command output should be
# redirected (combined stdout+stderr). When ARTIFACT_DIR is set — paid-beta-rc
# always sets one — logs land alongside summary.json so operators can diagnose
# failures without re-running anything. In dry-run / live modes that don't
# provide an artifact dir, output still goes to /dev/null (preserves prior
# behavior; those modes were never the diagnostic target).
#
# WHY: prior versions used `>/dev/null 2>&1` at every step callsite, which made
# RC failures diagnostically blind. summary.json could say "fail" but the
# operator had no way to recover the actual error. See test
# test_paid_beta_rc_writes_step_stderr_to_artifact_dir_on_cargo_failure.
_step_log_path() {
    local step_name="$1"
    if [ -n "$ARTIFACT_DIR" ]; then
        # ARTIFACT_DIR is created by ensure_rc_artifact_dir before any step runs;
        # mkdir -p is defensive in case a caller hasn't gone through that path.
        mkdir -p "$ARTIFACT_DIR" 2>/dev/null || true
        printf '%s/%s.log\n' "$ARTIFACT_DIR" "$step_name"
        return 0
    fi
    printf '/dev/null\n'
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
resolve_first_available_credential_value() {
    local key value value_status
    for key in "$@"; do
        value="$(resolve_credential_value "$key")" && { printf '%s\n' "$value"; return 0; }
        value_status=$?
        [ "$value_status" -eq 2 ] || [ "$value_status" -eq 3 ] && return "$value_status"
    done
    return 1
}
run_step_local_signoff() {
    local start_ms end_ms elapsed status reason
    start_ms="$(_ms_now)"
    local exit_code=0
    local log_path
    log_path="$(_step_log_path local_signoff)"
    bash "$LOCAL_SIGNOFF_SCRIPT" >"$log_path" 2>&1 || exit_code=$?
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
        status="external_secret_missing"
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
        append_step "ses_readiness" "external_secret_missing" "credentialed_env_file_parse_failed" "$elapsed"
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
            append_step "ses_readiness" "external_secret_missing" "credentialed_env_file_missing" "$elapsed"
            return 2
        fi
    fi
    local exit_code=0 log_path
    log_path="$(_step_log_path ses_readiness)"
    if [ "$ses_region_status" -eq 0 ] && [ -n "$ses_region" ]; then
        bash "$SES_READINESS_SCRIPT" --identity "$ses_identity" --region "$ses_region" >"$log_path" 2>&1 || exit_code=$?
    else
        bash "$SES_READINESS_SCRIPT" --identity "$ses_identity" >"$log_path" 2>&1 || exit_code=$?
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
        append_step "staging_billing_rehearsal" "external_secret_missing" "credentialed_billing_env_file_missing" "$elapsed"
        return 2
    fi
    if [ -z "$BILLING_MONTH" ]; then
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "staging_billing_rehearsal" "live_evidence_gap" "credentialed_billing_month_missing" "$elapsed"
        return 2
    fi
    local output="" exit_code=0 log_path
    # stdout is captured into $output for delegated-summary parsing; stderr is
    # redirected to the per-step log so operators can diagnose failures from
    # the artifact dir instead of losing them to /dev/null.
    log_path="$(_step_log_path staging_billing_rehearsal)"
    output="$(bash "$STAGING_BILLING_REHEARSAL_SCRIPT" \
        --env-file "$CREDENTIAL_ENV_FILE" \
        --month "$BILLING_MONTH" \
        --confirm-live-mutation 2>"$log_path")" || exit_code=$?
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    parse_delegated_billing_summary "$output"
    local delegated_result delegated_classification
    delegated_result="$DELEGATED_JSON_RESULT"
    delegated_classification="$DELEGATED_JSON_CLASSIFICATION"
    if [ "$delegated_result" = "blocked" ]; then
        status="live_evidence_gap"
        reason="$delegated_classification"
        if [ -z "$reason" ]; then
            reason="staging_billing_rehearsal_blocked"
        fi
    elif [ "$delegated_result" = "skipped" ] && [ "$exit_code" -eq 0 ]; then
        status="skipped"
        reason="$delegated_classification"
        if [ -z "$reason" ]; then
            reason="staging_billing_rehearsal_skipped"
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
    if [ "$status" = "pass" ] || [ "$status" = "skipped" ]; then
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
    local start_ms end_ms elapsed status reason log_path
    start_ms="$(_ms_now)"
    local exit_code=0
    log_path="$(_step_log_path "$step_name")"
    if [ -n "$working_dir" ]; then
        (
            cd "$working_dir"
            "$@"
        ) >"$log_path" 2>&1 || exit_code=$?
    else
        "$@" >"$log_path" 2>&1 || exit_code=$?
    fi
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    elif [ "$exit_code" -eq "$DELEGATED_SKIP_EXIT_CODE" ]; then
        status="skipped"
        reason="${step_name}_skipped"
    else
        status="fail"
        reason="$fail_reason"
    fi
    append_step "$step_name" "$status" "$reason" "$elapsed"
    if [ "$status" = "skipped" ]; then
        return 0
    fi
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
    local stage7_exit=0 stage8_exit=0 log_path
    # Single combined log for both stages so the operator sees them in order.
    log_path="$(_step_log_path terraform_static_guardrails)"
    build_terraform_stage7_static_command
    {
        echo "=== terraform_stage7_static ==="
        "${STEP_COMMAND[@]}"
    } >"$log_path" 2>&1 || stage7_exit=$?
    build_terraform_stage8_static_command
    {
        echo "=== terraform_stage8_static ==="
        "${STEP_COMMAND[@]}"
    } >>"$log_path" 2>&1 || stage8_exit=$?
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
        append_step "staging_runtime_smoke" "live_evidence_gap" "credentialed_staging_smoke_inputs_missing" "$elapsed"
        return 2
    fi
    build_staging_runtime_smoke_command
    run_delegated_command_step "staging_runtime_smoke" "staging_runtime_smoke_failed" "" "${STEP_COMMAND[@]}"
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
        local gate_args=("--sha=$sha")
        if [ "${STAGING_ONLY:-0}" = "1" ]; then
            gate_args+=("--staging-only")
        fi
        output="$(env LAUNCH_GATE_EVIDENCE_DIR="$ARTIFACT_DIR" COLLECT_EVIDENCE_DIR="$ARTIFACT_DIR" bash "$BACKEND_GATE_SCRIPT" "${gate_args[@]}")" || exit_code=$?
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
    STAGING_ONLY=0
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
execute_required_step() {
    local step_function="$1"
    shift
    if ! "$step_function" "$@"; then
        OVERALL_FAILED=1
        READY="false"
    fi
}
run_paid_beta_rc_rust_step() {
    local step_name="$1" fail_reason="$2" classify_skip_as_secret_missing="$3" command="$4"
    local start_ms end_ms elapsed output="" exit_code=0 log_path
    start_ms="$(_ms_now)"
    output="$(cd "$REPO_ROOT/infra" && bash -lc "$command" 2>&1)" || exit_code=$?
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    # Persist captured output to the per-step log so operators can diagnose
    # failures (and inspect skip markers) without re-running the rust step.
    # When ARTIFACT_DIR is unset, _step_log_path returns /dev/null and the
    # write is harmless — no need to guard the printf.
    log_path="$(_step_log_path "$step_name")"
    printf '%s' "$output" >"$log_path"
    if [ "$classify_skip_as_secret_missing" = "1" ] && [[ "$output" == *"SKIP:"* ]]; then
        append_step "$step_name" "external_secret_missing" "database_skip_marker" "$elapsed"
        return 2
    fi
    if [ "$exit_code" -eq 0 ]; then
        append_step "$step_name" "pass" "" "$elapsed"
        return 0
    fi
    append_step "$step_name" "fail" "$fail_reason" "$elapsed"
    return "$exit_code"
}
append_paid_beta_rc_constant_step() {
    local step_name="$1" status="$2" reason="$3"
    local start_ms end_ms elapsed
    start_ms="$(_ms_now)"
    end_ms="$(_ms_now)"
    elapsed=$((end_ms - start_ms))
    append_step "$step_name" "$status" "$reason" "$elapsed"
    if [ "$status" = "pass" ] || [ "$status" = "skipped" ]; then
        return 0
    fi
    return 2
}
append_staging_only_production_skip_step() {
    local step_name="$1"
    append_paid_beta_rc_constant_step "$step_name" "skipped" "$STAGING_ONLY_PRODUCTION_SKIP_REASON"
}
run_step_paid_beta_rc_ses_inbound() {
    local start_ms end_ms elapsed exit_code=0 ses_identity="" ses_region=""
    local ses_identity_status=0 ses_region_status=0
    start_ms="$(_ms_now)"
    ses_identity="$(resolve_credential_value "SES_FROM_ADDRESS")" || ses_identity_status=$?
    ses_region="$(resolve_credential_value "SES_REGION")" || ses_region_status=$?
    if [ "$ses_identity_status" -ne 0 ] || [ "$ses_region_status" -ne 0 ]; then
        end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
        append_step "ses_inbound" "external_secret_missing" "credentialed_ses_inbound_inputs_missing" "$elapsed"; return 2
    fi
    local log_path
    log_path="$(_step_log_path ses_inbound)"
    env SES_FROM_ADDRESS="$ses_identity" SES_REGION="$ses_region" bash "$SES_INBOUND_ROUNDTRIP_SCRIPT" >"$log_path" 2>&1 || exit_code=$?
    end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
    case "$exit_code" in
        0) append_step "ses_inbound" "pass" "" "$elapsed" ;;
        21) append_step "ses_inbound" "fail" "ses_inbound_roundtrip_timeout" "$elapsed" ;;
        22) append_step "ses_inbound" "fail" "ses_inbound_auth_verdict_failed" "$elapsed" ;;
        1) append_step "ses_inbound" "fail" "ses_inbound_roundtrip_runtime_failed" "$elapsed" ;;
        2) append_step "ses_inbound" "fail" "ses_inbound_roundtrip_usage_failed" "$elapsed" ;;
        *) append_step "ses_inbound" "fail" "ses_inbound_roundtrip_runtime_failed" "$elapsed" ;;
    esac
    [ "$exit_code" -eq 0 ] && return 0
    return "$exit_code"
}
run_step_paid_beta_rc_canary_customer_loop() {
    local start_ms end_ms elapsed exit_code=0 canary_admin_key="" canary_stripe_key=""
    local canary_admin_key_status=0 canary_stripe_key_status=0
    start_ms="$(_ms_now)"
    canary_admin_key="$(resolve_first_available_credential_value "ADMIN_KEY" "FLAPJACK_ADMIN_KEY")" || canary_admin_key_status=$?
    canary_stripe_key="$(resolve_first_available_credential_value "STRIPE_SECRET_KEY" "STRIPE_TEST_SECRET_KEY")" || canary_stripe_key_status=$?
    if [ "$canary_admin_key_status" -ne 0 ] || [ "$canary_stripe_key_status" -ne 0 ]; then
        end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
        append_step "canary_customer_loop" "external_secret_missing" "credentialed_canary_customer_loop_inputs_missing" "$elapsed"; return 2
    fi
    local log_path
    log_path="$(_step_log_path canary_customer_loop)"
    env ADMIN_KEY="$canary_admin_key" STRIPE_SECRET_KEY="$canary_stripe_key" CANARY_RC_READINESS_MODE=1 bash "$CANARY_CUSTOMER_LOOP_SCRIPT" >"$log_path" 2>&1 || exit_code=$?
    end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        append_step "canary_customer_loop" "pass" "" "$elapsed"; return 0
    fi
    append_step "canary_customer_loop" "fail" "canary_customer_loop_failed" "$elapsed"
    return "$exit_code"
}
run_required_paid_beta_rc_steps() {
    execute_required_step run_step_local_signoff
    execute_required_step run_step_ses_readiness
    execute_required_step run_step_staging_billing_rehearsal
    execute_required_step run_step_browser_preflight
    execute_required_step run_step_browser_auth_setup
    execute_required_step run_step_terraform_static_guardrails
    execute_required_step run_step_staging_runtime_smoke
    if [ "${STAGING_ONLY:-0}" = "1" ]; then
        execute_required_step append_staging_only_production_skip_step "admin_broadcast"
        execute_required_step append_staging_only_production_skip_step "billing_health_last_activity"
        execute_required_step append_staging_only_production_skip_step "audit_timeline"
        execute_required_step append_staging_only_production_skip_step "status_runtime"
        execute_required_step append_staging_only_production_skip_step "ses_inbound"
        execute_required_step append_staging_only_production_skip_step "canary_customer_loop"
        execute_required_step append_staging_only_production_skip_step "canary_outside_aws"
        execute_required_step append_staging_only_production_skip_step "stripe_webhook_signature_matrix_idempotency"
        execute_required_step append_staging_only_production_skip_step "test_clock"
        execute_required_step append_staging_only_production_skip_step "tenant_isolation"
        execute_required_step append_staging_only_production_skip_step "signup_abuse"
        execute_required_step append_staging_only_production_skip_step "browser_signup_paid"
        execute_required_step append_staging_only_production_skip_step "browser_portal_cancel"
        return 0
    fi
    execute_required_step run_paid_beta_rc_rust_step "admin_broadcast" "admin_broadcast_failed" "1" "\"$CARGO_BIN\" test -p api --test admin_broadcast_test -- --ignored"
    execute_required_step run_paid_beta_rc_rust_step "billing_health_last_activity" "billing_health_last_activity_failed" "1" "\"$CARGO_BIN\" test -p api --test pg_customer_repo_test && \"$CARGO_BIN\" test -p api --test tenants_test"
    execute_required_step run_paid_beta_rc_rust_step "audit_timeline" "audit_timeline_failed" "1" "\"$CARGO_BIN\" test -p api --test admin_audit_view_test -- --ignored && \"$CARGO_BIN\" test -p api --test admin_token_audit_test -- --ignored"
    execute_required_step run_paid_beta_rc_rust_step "status_runtime" "status_runtime_failed" "0" "\"$CARGO_BIN\" test -p api --test onboarding_test status_response_uses_region_not_deployment_field_names"
    execute_required_step run_step_paid_beta_rc_ses_inbound
    execute_required_step run_step_paid_beta_rc_canary_customer_loop
    execute_required_step run_delegated_command_step "canary_outside_aws" "canary_outside_aws_failed" "" bash "$OUTSIDE_AWS_HEALTH_SCRIPT"
    execute_required_step run_paid_beta_rc_rust_step "stripe_webhook_signature_matrix_idempotency" "stripe_webhook_signature_matrix_idempotency_failed" "0" "\"$CARGO_BIN\" test -p api --test stripe_webhook_signature_test && \"$CARGO_BIN\" test -p api --test stripe_webhook_event_matrix_test && \"$CARGO_BIN\" test -p api --test stripe_webhook_idempotency_test"
    execute_required_step append_paid_beta_rc_constant_step "test_clock" "live_evidence_gap" "stripe_test_clock_full_cycle_owner_requires_live_mode"
    execute_required_step run_paid_beta_rc_rust_step "tenant_isolation" "tenant_isolation_failed" "0" "\"$CARGO_BIN\" test -p api --test tenant_isolation_proptest tenant_isolation_proptest_route_family"
    execute_required_step run_paid_beta_rc_rust_step "signup_abuse" "signup_abuse_failed" "0" "\"$CARGO_BIN\" test -p api --test signup_abuse_test"
    execute_required_step append_paid_beta_rc_constant_step "browser_signup_paid" "skipped" "browser_signup_paid_readiness_mode_missing"
    execute_required_step append_paid_beta_rc_constant_step "browser_portal_cancel" "skipped" "browser_portal_cancel_readiness_mode_missing"
}
is_critical_browser_step() {
    local step_name="$1"
    local critical
    for critical in "${CRITICAL_BROWSER_STEPS[@]}"; do
        if [ "$critical" = "$step_name" ]; then
            return 0
        fi
    done
    return 1
}
promote_critical_browser_skip_failures() {
    local idx
    for idx in "${!STEP_NAMES[@]}"; do
        if ! is_critical_browser_step "${STEP_NAMES[$idx]}"; then
            continue
        fi
        if [ "${STEP_STATUSES[$idx]}" = "skipped" ]; then
            if [ "${STEP_REASONS[$idx]}" = "$STAGING_ONLY_PRODUCTION_SKIP_REASON" ]; then
                continue
            fi
            STEP_STATUSES[$idx]="fail"
            STEP_REASONS[$idx]="critical_surface_skipped"
        fi
    done
}
recompute_outcome_from_steps() {
    OVERALL_FAILED=0
    READY="true"
    local status
    for status in "${STEP_STATUSES[@]}"; do
        case "$status" in
            pass|skipped)
                ;;
            fail|live_evidence_gap|external_secret_missing)
                OVERALL_FAILED=1
                READY="false"
                return 0
                ;;
            *)
                OVERALL_FAILED=1
                READY="false"
                return 0
                ;;
        esac
    done
}
emit_final_result() {
    local start_ms="$1"
    promote_critical_browser_skip_failures
    recompute_outcome_from_steps
    local verdict="pass"
    if [ "$OVERALL_FAILED" -ne 0 ]; then
        verdict="fail"
    fi
    local final_json
    final_json="$(emit_result_json "$verdict" "$MODE" "$start_ms" "$READY")"
    if [ "$MODE" = "paid_beta_rc" ] && [ -n "$ARTIFACT_DIR" ]; then
        printf '%s\n' "$final_json" > "$ARTIFACT_DIR/summary.json"
    fi
    printf '%s\n' "$final_json"
    [ "$OVERALL_FAILED" -ne 0 ] && return 1
    return 0
}
run_full_backend_validation() {
    local start_ms
    start_ms="$(_ms_now)"
    reset_run_state
    local parse_status
    parse_cli_args "$@" || parse_status=$?
    [ "${parse_status:-0}" -eq 10 ] && return 0
    [ "${parse_status:-0}" -ne 0 ] && return "$parse_status"
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
