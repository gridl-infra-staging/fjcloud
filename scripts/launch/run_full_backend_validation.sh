#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2004,SC2016
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
source "$REPO_ROOT/scripts/lib/rc_invocation.sh"
source "$REPO_ROOT/scripts/lib/test_inbox_helpers.sh"
source "$REPO_ROOT/scripts/lib/web_runtime.sh"
CARGO_BIN="${FULL_VALIDATION_CARGO_BIN:-cargo}"
BACKEND_GATE_SCRIPT="${FULL_VALIDATION_BACKEND_GATE_SCRIPT:-$REPO_ROOT/scripts/launch/backend_launch_gate.sh}"
LOCAL_SIGNOFF_SCRIPT="${FULL_VALIDATION_LOCAL_SIGNOFF_SCRIPT:-$REPO_ROOT/scripts/local-signoff.sh}"
SES_READINESS_SCRIPT="${FULL_VALIDATION_SES_READINESS_SCRIPT:-$REPO_ROOT/scripts/validate_ses_readiness.sh}"
STAGING_BILLING_REHEARSAL_SCRIPT="${FULL_VALIDATION_STAGING_BILLING_REHEARSAL_SCRIPT:-$REPO_ROOT/scripts/staging_billing_rehearsal.sh}"
STRIPE_VALIDATION_SCRIPT="${FULL_VALIDATION_STRIPE_VALIDATION_SCRIPT:-$REPO_ROOT/scripts/validate-stripe.sh}"
BROWSER_PREFLIGHT_SCRIPT="${FULL_VALIDATION_BROWSER_PREFLIGHT_SCRIPT:-$REPO_ROOT/scripts/e2e-preflight.sh}"
BROWSER_LANE_SCRIPT="${FULL_VALIDATION_BROWSER_LANE_SCRIPT:-$REPO_ROOT/scripts/launch/run_browser_lane_against_staging.sh}"
TERRAFORM_STAGE7_STATIC_SCRIPT="${FULL_VALIDATION_TERRAFORM_STAGE7_STATIC_SCRIPT:-$REPO_ROOT/ops/terraform/tests_stage7_static.sh}"
TERRAFORM_STAGE8_STATIC_SCRIPT="${FULL_VALIDATION_TERRAFORM_STAGE8_STATIC_SCRIPT:-$REPO_ROOT/ops/terraform/tests_stage8_static.sh}"
TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT="${FULL_VALIDATION_TERRAFORM_STAGE7_RUNTIME_SMOKE_SCRIPT:-$REPO_ROOT/ops/terraform/tests_stage7_runtime_smoke.sh}"
PLAYWRIGHT_BIN="${FULL_VALIDATION_PLAYWRIGHT_BIN:-npx}"
PLAYWRIGHT_WEB_DIR="${FULL_VALIDATION_PLAYWRIGHT_WEB_DIR:-$REPO_ROOT/web}"
WEB_RUNTIME_REPO_ROOT="${FULL_VALIDATION_WEB_RUNTIME_REPO_ROOT:-$REPO_ROOT}"
OUTSIDE_AWS_HEALTH_SCRIPT="${FULL_VALIDATION_OUTSIDE_AWS_HEALTH_SCRIPT:-$REPO_ROOT/scripts/canary/outside_aws_health_check.sh}"
SES_INBOUND_ROUNDTRIP_SCRIPT="${FULL_VALIDATION_SES_INBOUND_ROUNDTRIP_SCRIPT:-$REPO_ROOT/scripts/validate_inbound_email_roundtrip.sh}"
CANARY_CUSTOMER_LOOP_SCRIPT="${FULL_VALIDATION_CANARY_CUSTOMER_LOOP_SCRIPT:-$REPO_ROOT/scripts/canary/customer_loop_synthetic.sh}"
SHA_OVERRIDE=""
MODE="live"
ARTIFACT_DIR=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
STAGING_SMOKE_API_AMI_ID=""
STAGING_SMOKE_FLAPJACK_AMI_ID=""
SECTION1_MANIFEST=""
STAGING_ONLY=0
LIST_PAID_BETA_STEPS=0
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
BROWSER_CREDENTIAL_ENV_KEYS=(
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    AWS_DEFAULT_REGION
    AWS_REGION
    AWS_PROFILE
    AWS_CONFIG_FILE
    AWS_SHARED_CREDENTIALS_FILE
    AWS_CA_BUNDLE
    AWS_ROLE_ARN
    AWS_WEB_IDENTITY_TOKEN_FILE
)
print_usage() {
    cat <<'USAGE'
Usage:
  run_full_backend_validation.sh [--dry-run] [--sha=<GIT_SHA>]
  run_full_backend_validation.sh --paid-beta-rc [--staging-only] [--sha=<GIT_SHA>] [--artifact-dir=<dir>] [--credential-env-file=<path>] [--billing-month=<YYYY-MM>] --section1-manifest=<path> [--staging-smoke-api-ami-id=<ami-id>] [--staging-smoke-flapjack-ami-id=<ami-id>]
  run_full_backend_validation.sh --list-paid-beta-steps
  run_full_backend_validation.sh --help
Options:
  --dry-run                      Run in dry-run mode (stubs external dependency checks via backend gate DRY_RUN=1)
  --paid-beta-rc                 Run paid beta RC readiness mode with required delegated proofs
  --staging-only                 RC sub-mode: run staging proofs, soft-skip production-facing proofs
  --sha=<40-char-sha>            Commit SHA to validate in backend launch gate
  --artifact-dir=<dir>           Artifact directory used for delegated launch evidence outputs
  --credential-env-file=<path>   Optional credentials env file (KEY=value) for RC delegated proof inputs
  --billing-month=<YYYY-MM>      Billing month for RC staging billing rehearsal
  --section1-manifest=<path>     Complete §1 in-VPC runner manifest to bind RC classification
  --staging-smoke-api-ami-id=<ami-id>
                                 API instance AMI opt-in input for RC staging runtime smoke proof
  --staging-smoke-flapjack-ami-id=<ami-id>
                                 Flapjack runtime-pointer AMI opt-in input for RC staging runtime smoke proof
  --only-steps=<csv>             Run only the named paid-beta RC steps, validating names here
  --list-paid-beta-steps         Emit the paid-beta RC step registry as stable JSON without running steps
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
    if ! resolve_stripe_secret_key >/dev/null 2>&1; then
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
credential_env_assignment_value() {
    local target_key="$1"
    local line parse_status

    if [ -z "$CREDENTIAL_ENV_FILE" ] || [ ! -f "$CREDENTIAL_ENV_FILE" ] || [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -ne 0 ]; then
            continue
        fi
        if [ "$ENV_ASSIGNMENT_KEY" = "$target_key" ]; then
            printf '%s\n' "$ENV_ASSIGNMENT_VALUE"
            return 0
        fi
    done < "$CREDENTIAL_ENV_FILE"

    return 1
}

is_wrapper_hydrated_staging_db_value() {
    local value="$1"

    case "$value" in
        *staging*|*internal*|*.rds.amazonaws.com*|*amazonaws.com*)
            return 0
            ;;
    esac

    return 1
}

scope_paid_beta_local_db_key() {
    local key="$1"
    local credential_value

    if credential_value="$(credential_env_assignment_value "$key")"; then
        printf -v "$key" '%s' "$credential_value"
        export "${key?}"
        return 0
    fi

    if [ "${!key+x}" = "x" ] && is_wrapper_hydrated_staging_db_value "${!key}"; then
        unset "$key"
    fi
}

apply_rc_step_env_scope() {
    local step_class="$1"

    case "$step_class" in
        workspace_cargo_smoke)
            # cargo test --workspace is the workspace smoke gate — it must NOT
            # inherit operator-supplied DATABASE_URL / INTEGRATION_DB_URL from
            # the parent shell. pg-bound tests skip cleanly when DATABASE_URL is
            # unset, but panic when it is set to staging-internal hosts that are
            # unreachable from a dev laptop.
            unset DATABASE_URL INTEGRATION_DB_URL
            ;;
        paid_beta_local_db_rust)
            scope_paid_beta_local_db_key DATABASE_URL
            scope_paid_beta_local_db_key INTEGRATION_DB_URL
            ;;
        local_browser_setup)
            unset API_URL API_BASE_URL STAGING_API_URL
            ;;
        *)
            echo "ERROR: unknown RC step env scope '$step_class'" >&2
            return 2
            ;;
    esac
}

with_local_browser_setup_env_scope_command() {
    STEP_COMMAND=(env -u API_URL -u API_BASE_URL -u STAGING_API_URL)
    STEP_COMMAND+=("$@")
}

run_step_cargo_tests() {
    local start_ms end_ms elapsed status reason log_path
    start_ms="$(_ms_now)"
    local exit_code=0
    log_path="$(_step_log_path cargo_workspace_tests)"
    (
        cd "$REPO_ROOT/infra"
        apply_rc_step_env_scope workspace_cargo_smoke
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
    local default_artifact_parent
    default_artifact_parent="$REPO_ROOT/.local/paid_beta_rc_artifacts"
    mkdir -p "$default_artifact_parent"
    ARTIFACT_DIR="$(mktemp -d "$default_artifact_parent/fjcloud_paid_beta_rc_XXXXXX")"
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
# Match any of the supplied extended-regex patterns against the captured log.
# Returns 0 if any match; 1 otherwise (including when log_path is missing).
# Used by step functions to distinguish env-gap failures (missing credentials,
# missing deps, unreachable services, misconfigured admin keys) from real
# customer-impact defects. Env-gap matches let the step reclassify "fail" to
# "external_secret_missing", which the verdict translator tolerates instead
# of counting as a real "other" failure that would drive plain NOT-READY.
#
# Generic non-zero exits WITHOUT these patterns continue to classify as
# "fail" and drive real-defect verdicts.
_log_matches_env_gap_pattern() {
    local log_path="$1"
    shift
    if [ ! -f "$log_path" ] || [ ! -s "$log_path" ]; then
        return 1
    fi
    local pattern
    for pattern in "$@"; do
        if grep -qE "$pattern" "$log_path" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

canonical_canary_customer_loop_skip_reason_from_log() {
    local log_path="$1"
    local skip_line skip_payload skip_reason

    if [ ! -f "$log_path" ] || [ ! -s "$log_path" ]; then
        return 1
    fi

    skip_line="$(grep -m1 '^SKIPPED: ' "$log_path" 2>/dev/null || true)"
    if [ -z "$skip_line" ]; then
        return 1
    fi

    skip_payload="${skip_line#SKIPPED: }"
    skip_reason="${skip_payload%%:*}"
    case "$skip_reason" in
        "$TEST_INBOX_AWS_CREDENTIALS_UNAVAILABLE_TOKEN"|"$TEST_INBOX_AWS_CREDENTIALS_INVALID_TOKEN"|"$TEST_INBOX_AWS_INBOX_ENV_MISSING_TOKEN")
            printf '%s\n' "$skip_reason"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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
resolve_paid_beta_rc_test_clock_stripe_key() {
    local value="" value_status=0
    if [ -n "$CREDENTIAL_ENV_FILE" ] && [ -f "$CREDENTIAL_ENV_FILE" ] && [ -r "$CREDENTIAL_ENV_FILE" ]; then
        value="$(read_env_value_from_file "$CREDENTIAL_ENV_FILE" "STRIPE_TEST_SECRET_KEY")" || value_status=$?
        if [ "$value_status" -eq 2 ]; then
            return 2
        fi
        if [ "$value_status" -eq 0 ] && [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi
    resolve_first_available_credential_value "STRIPE_SECRET_KEY" "STRIPE_TEST_SECRET_KEY"
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
    elif _log_matches_env_gap_pattern "$log_path" \
            'REASON: prerequisite_missing' \
            'Strict signoff prerequisites invalid' \
            'ERROR: missing:flapjack_binary'; then
        # local-signoff aborts immediately on missing local-dev prereqs
        # (STRIPE_LOCAL_MODE, COLD_STORAGE_*, FLAPJACK_REGIONS, MAILPIT_API_URL,
        # flapjack_binary). These are harness-env gaps, not customer-impact
        # defects — the corresponding cargo tests are already covered under
        # required_paid_beta_rc_steps via cargo_workspace_tests.
        if [ "$MODE" = "paid_beta_rc" ]; then
            status="skipped"
            reason="local_signoff_not_applicable_in_paid_beta_rc_mode"
        else
            status="external_secret_missing"
            reason="local_signoff_prerequisites_unsatisfied"
        fi
    else
        status="fail"
        reason="local_signoff_failed"
    fi
    append_step "local_signoff" "$status" "$reason" "$elapsed"
    if [ "$status" = "pass" ] || [ "$status" = "skipped" ] || [ "$status" = "external_secret_missing" ]; then
        return 0
    fi
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
# Requires STAGING_CLOUD_URL / STAGING_API_URL to already be hydrated; the caller
# (run_step_browser_auth_setup) fails closed before invoking this so the staging
# proof can never silently fall back to ambient/local BASE_URL / API_URL defaults.
build_browser_auth_setup_command() {
    local browser_base_url="$STAGING_CLOUD_URL"
    local browser_api_url="$STAGING_API_URL"
    STEP_COMMAND=(
        env
        "BASE_URL=$browser_base_url" "PLAYWRIGHT_BASE_URL=$browser_base_url"
        "API_URL=$browser_api_url" "API_BASE_URL=$browser_api_url"
        PLAYWRIGHT_TARGET_REMOTE=1 \
        "$PLAYWRIGHT_BIN" playwright test \
        -c playwright.config.ts \
        tests/fixtures/auth.setup.ts \
        tests/fixtures/admin.auth.setup.ts \
        --project=setup:user \
        --project=setup:admin \
        --reporter=line
    )
}
is_browser_credential_env_key() {
    local key="$1"
    local allowed_key
    for allowed_key in "${BROWSER_CREDENTIAL_ENV_KEYS[@]}"; do
        if [ "$allowed_key" = "$key" ]; then
            return 0
        fi
    done
    return 1
}
write_filtered_browser_credential_env_file() {
    local source_env_file="$1"
    local target_env_file="$2"
    local line line_number=0 parse_status
    : > "$target_env_file"
    if [ -z "$source_env_file" ]; then
        return 0
    fi
    if [ ! -f "$source_env_file" ] || [ ! -r "$source_env_file" ]; then
        echo "ERROR: Credential env file not readable: $source_env_file" >&2
        return 3
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if is_browser_credential_env_key "$ENV_ASSIGNMENT_KEY"; then
                printf '%s=%s\n' "$ENV_ASSIGNMENT_KEY" "$ENV_ASSIGNMENT_VALUE" >> "$target_env_file"
            fi
            continue
        fi
        if [ "$parse_status" -eq 2 ]; then
            continue
        fi
        echo "ERROR: Unsupported syntax in ${source_env_file} at line ${line_number}; only KEY=value assignments are allowed" >&2
        return 2
    done < "$source_env_file"
}
build_paid_beta_rc_browser_lane_command() {
    local canonical_lane="$1"
    local step_name="$2"
    local filtered_env_file="$3"
    local credential_key
    STEP_COMMAND=(env)
    for credential_key in "${BROWSER_CREDENTIAL_ENV_KEYS[@]}"; do
        STEP_COMMAND+=("-u" "$credential_key")
    done
    STEP_COMMAND+=(
        bash -c 'set -euo pipefail; source "$1"; load_env_file "$2"; shift 2; exec "$@"' _
        "$REPO_ROOT/scripts/lib/env.sh"
        "$filtered_env_file"
        bash "$BROWSER_LANE_SCRIPT"
        --lane "$canonical_lane"
        --evidence-dir "$ARTIFACT_DIR/$step_name"
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
        --api-ami-id "$STAGING_SMOKE_API_AMI_ID"
        --flapjack-ami-id "$STAGING_SMOKE_FLAPJACK_AMI_ID"
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
    {
        if [ -n "$working_dir" ]; then
            printf 'Working directory: %s\n' "$working_dir"
        fi
        printf 'Delegated command:'
        printf ' %q' "$@"
        printf '\n'
    } >"$log_path"
    if [ -n "$working_dir" ]; then
        (
            cd "$working_dir"
            "$@"
        ) >>"$log_path" 2>&1 || exit_code=$?
    else
        "$@" >>"$log_path" 2>&1 || exit_code=$?
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
        # Per-step env-gap reclassification: when the captured log contains a
        # known harness-env-gap fingerprint (missing deps, unreachable services,
        # local-dev preconditions absent), upgrade status to
        # "external_secret_missing" so the verdict translator treats it as
        # tolerated. Real customer-impact regressions don't match these
        # patterns and stay "fail".
        case "$step_name" in
            browser_preflight|browser_auth_setup|browser_signup_paid|browser_portal_cancel)
                if _log_matches_env_gap_pattern "$log_path" \
                        'Cannot find module .*@playwright' \
                        'Please run.*playwright install' \
                        'browserType\.launch.*Executable doesn'\''t exist' \
                        'npx: command not found' \
                        'Run scripts/bootstrap-env-local\.sh' \
                        'ADMIN_KEY is required' \
                        'ADMIN_KEY not hydrated from SSM' \
                        'STRIPE_SECRET_KEY not hydrated from SSM' \
                        'STRIPE_WEBHOOK_SECRET not hydrated from SSM' \
                        'Unable to locate credentials' \
                        'The security token included in the request is invalid' \
                        'ExpiredToken' \
                        'UnrecognizedClientException' \
                        'AccessDeniedException' \
                        'BASE_URL .* not reachable' \
                        'API_BASE_URL .* not reachable' \
                        'connect ECONNREFUSED' \
                        'connection refused' \
                        'getaddrinfo ENOTFOUND' \
                        'ENVIRONMENT must be local' \
                        'PREFLIGHT FAILED'; then
                    status="external_secret_missing"
                    reason="${step_name}_env_gap"
                fi
                ;;
            canary_outside_aws)
                if _log_matches_env_gap_pattern "$log_path" \
                        'curl.*Could not resolve host' \
                        'curl.*Connection refused' \
                        'curl: \(28\)' \
                        'curl: \(6\)' \
                        'curl: \(7\)' \
                        'curl: \(35\)'; then
                    status="external_secret_missing"
                    reason="${step_name}_env_gap"
                fi
                ;;
        esac
    fi
    append_step "$step_name" "$status" "$reason" "$elapsed"
    if [ "$status" = "skipped" ] || [ "$status" = "external_secret_missing" ]; then
        return 0
    fi
    return "$exit_code"
}
run_step_browser_preflight() {
    build_browser_preflight_command
    run_delegated_command_step "browser_preflight" "browser_preflight_failed" "" "${STEP_COMMAND[@]}"
}
run_step_browser_auth_setup() {
    local start_ms end_ms elapsed log_path
    start_ms="$(_ms_now)"
    if ! has_web_playwright_test_runtime "$WEB_RUNTIME_REPO_ROOT"; then
        log_path="$(_step_log_path browser_auth_setup)"
        # Match run_browser_lane_against_staging.sh's fail-closed runtime
        # contract before invoking npx, which can otherwise pull a transient
        # Playwright package that cannot import this repo's config deps.
        printf 'ERROR: %s — owner: scripts/launch/run_full_backend_validation.sh\n' \
            "$(web_playwright_test_runtime_missing_message)" >"$log_path"
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "browser_auth_setup" "external_secret_missing" "browser_auth_setup_env_gap" "$elapsed"
        return 0
    fi
    # Fail closed on missing staging targets: this step proves auth against the
    # deployed staging environment, so it must never fall back to ambient/local
    # BASE_URL / API_URL (which playwright.config.ts fills with localhost
    # defaults) and silently certify the wrong system.
    if [ -z "${STAGING_CLOUD_URL:-}" ] || [ -z "${STAGING_API_URL:-}" ]; then
        log_path="$(_step_log_path browser_auth_setup)"
        printf 'ERROR: browser_auth_setup requires hydrated staging targets (STAGING_CLOUD_URL and STAGING_API_URL); refusing to fall back to ambient/local BASE_URL/API_URL — owner: scripts/launch/run_full_backend_validation.sh\n' \
            >"$log_path"
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "browser_auth_setup" "fail" "browser_auth_setup_staging_target_missing" "$elapsed"
        return 1
    fi
    build_browser_auth_setup_command
    run_delegated_command_step "browser_auth_setup" "browser_auth_setup_failed" "$PLAYWRIGHT_WEB_DIR" "${STEP_COMMAND[@]}"
}
run_step_paid_beta_rc_browser_lane() {
    local step_name="$1"
    local canonical_lane="$2"
    local fail_reason="$3"
    local start_ms end_ms elapsed log_path
    start_ms="$(_ms_now)"
    log_path="$(_step_log_path "$step_name")"
    if ! has_web_playwright_test_runtime "$WEB_RUNTIME_REPO_ROOT"; then
        printf 'ERROR: %s — owner: scripts/launch/run_full_backend_validation.sh\n' \
            "$(web_playwright_test_runtime_missing_message)" >"$log_path"
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        append_step "$step_name" "external_secret_missing" "${step_name}_env_gap" "$elapsed"
        return 0
    fi
    local filtered_env_file filter_status=0
    local temp_parent
    temp_parent="${TMPDIR:-/tmp}"
    filtered_env_file="$(mktemp "$temp_parent/fjcloud_${step_name}_credential_env.XXXXXX")"
    write_filtered_browser_credential_env_file "$CREDENTIAL_ENV_FILE" "$filtered_env_file" >"$log_path" 2>&1 || filter_status=$?
    if [ "$filter_status" -ne 0 ]; then
        rm -f "$filtered_env_file"
        end_ms="$(_ms_now)"
        elapsed=$((end_ms - start_ms))
        case "$filter_status" in
            2)
                append_step "$step_name" "external_secret_missing" "credentialed_browser_env_file_parse_failed" "$elapsed"
                ;;
            3)
                append_step "$step_name" "external_secret_missing" "credentialed_browser_env_file_missing" "$elapsed"
                ;;
            *)
                append_step "$step_name" "external_secret_missing" "${step_name}_env_gap" "$elapsed"
                ;;
        esac
        return 0
    fi
    local delegated_status=0
    build_paid_beta_rc_browser_lane_command "$canonical_lane" "$step_name" "$filtered_env_file"
    run_delegated_command_step "$step_name" "$fail_reason" "" "${STEP_COMMAND[@]}" || delegated_status=$?
    rm -f "$filtered_env_file"
    return "$delegated_status"
}
run_step_paid_beta_rc_browser_signup_paid() {
    run_step_paid_beta_rc_browser_lane "browser_signup_paid" "signup_to_paid_invoice" "browser_signup_paid_failed"
}
run_step_paid_beta_rc_browser_portal_cancel() {
    run_step_paid_beta_rc_browser_lane "browser_portal_cancel" "billing_portal_payment_method_update" "browser_portal_cancel_failed"
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
    if [ -z "$STAGING_SMOKE_API_AMI_ID" ] || [ -z "$STAGING_SMOKE_FLAPJACK_AMI_ID" ] || [ -z "$CREDENTIAL_ENV_FILE" ] || [ ! -f "$CREDENTIAL_ENV_FILE" ] || [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
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
        local gate_args=("--sha=$sha" "--staging-only")
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
        # The commerce gate's three local-only checks
        # (check_stripe_webhook_forwarding requires `stripe listen` running
        # locally; check_usage_records_populated + check_rollup_current require
        # DATABASE_URL pointing at a populated metering DB) are harness-env
        # preconditions, not customer-impact gates. Live-mode webhook +
        # metering correctness are proven separately under §2 Rust tests
        # (`stripe_webhook_signature_test.rs`, `integration_metering_pipeline_test.rs`)
        # whose evidence lives in `billing_coverage_a2/20260525T*`. Persist the
        # commerce-gate JSON so the upgrade is auditable.
        local commerce_log
        commerce_log="$(_step_log_path backend_launch_gate)"
        printf '%s' "$output" >"$commerce_log"
        # When the commerce gate's `reason` field lists ONLY the three
        # known env-gap check names, the failure is harness-env, not real.
        # The names are stable identifiers in the commerce-checks owner
        # (scripts/lib/stripe_checks.sh + scripts/lib/metering_checks.sh)
        # and the gate emits them in JSON via live-backend-gate's wrapper.
        if _log_matches_env_gap_pattern "$commerce_log" \
                '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current"' \
                '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_rollup_current, check_usage_records_populated"' \
                '"name": *"commerce", *"reason": *"check_usage_records_populated, check_stripe_webhook_forwarding, check_rollup_current"' \
                '"name": *"commerce", *"reason": *"check_usage_records_populated, check_rollup_current, check_stripe_webhook_forwarding"' \
                '"name": *"commerce", *"reason": *"check_rollup_current, check_stripe_webhook_forwarding, check_usage_records_populated"' \
                '"name": *"commerce", *"reason": *"check_rollup_current, check_usage_records_populated, check_stripe_webhook_forwarding"'; then
            status="external_secret_missing"
            reason="backend_launch_gate_commerce_local_env_missing"
        fi
    fi
    append_step "backend_launch_gate" "$status" "$reason" "$elapsed"
    if [ "$status" = "pass" ] || [ "$status" = "external_secret_missing" ]; then
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
    STAGING_SMOKE_API_AMI_ID=""
    STAGING_SMOKE_FLAPJACK_AMI_ID=""
    # shellcheck disable=SC2034 # Parsed in scripts/lib/full_backend_validation_cli.sh.
    SECTION1_MANIFEST=""
    STAGING_ONLY=0
    LIST_PAID_BETA_STEPS=0
    ONLY_STEPS_CSV=""
    ONLY_STEP_NAMES=()
    # EXPLICIT_MODE is read by scripts/lib/full_backend_validation_cli.sh.
    # shellcheck disable=SC2034
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
parse_only_steps_csv() {
    ONLY_STEP_NAMES=()
    if [ -z "$ONLY_STEPS_CSV" ]; then
        return 0
    fi
    local remaining token existing
    remaining="$ONLY_STEPS_CSV"
    while :; do
        token="${remaining%%,*}"
        if [ -z "$token" ]; then
            echo "ERROR: --only-steps contains an empty step name" >&2
            return 2
        fi
        if [ "${#ONLY_STEP_NAMES[@]}" -gt 0 ]; then
            for existing in "${ONLY_STEP_NAMES[@]}"; do
                if [ "$existing" = "$token" ]; then
                    echo "ERROR: --only-steps contains duplicate step name '$token'" >&2
                    return 2
                fi
            done
        fi
        ONLY_STEP_NAMES+=("$token")
        if [ "$remaining" = "$token" ]; then
            break
        fi
        remaining="${remaining#*,}"
    done
}
only_step_requested() {
    local step_name="$1" requested
    if [ "${#ONLY_STEP_NAMES[@]}" -eq 0 ]; then
        return 0
    fi
    for requested in "${ONLY_STEP_NAMES[@]}"; do
        if [ "$requested" = "$step_name" ]; then
            return 0
        fi
    done
    return 1
}
registry_contains_step() {
    local step_name="$1" registered
    for registered in "${REGISTERED_STEP_NAMES[@]:-}"; do
        if [ "$registered" = "$step_name" ]; then
            return 0
        fi
    done
    return 1
}
register_required_step() {
    local step_name="$1" step_function="$2"
    shift 2
    case "$STEP_REGISTRY_MODE" in
        collect)
            REGISTERED_STEP_NAMES+=("$step_name")
            ;;
        execute)
            if only_step_requested "$step_name"; then
                execute_required_step "$step_function" "$@"
            fi
            ;;
        execute_one)
            if [ "$step_name" = "$CURRENT_ONLY_STEP" ]; then
                execute_required_step "$step_function" "$@"
            fi
            ;;
        *)
            echo "ERROR: unknown step registry mode '$STEP_REGISTRY_MODE'" >&2
            return 2
            ;;
    esac
}
visit_paid_beta_rc_step_registry() {
    register_required_step "cargo_workspace_tests" run_step_cargo_tests
    register_required_step "backend_launch_gate" run_step_backend_launch_gate "$RESOLVED_SHA"
    register_required_step "local_signoff" run_step_local_signoff
    register_required_step "ses_readiness" run_step_ses_readiness
    register_required_step "staging_billing_rehearsal" run_step_staging_billing_rehearsal
    register_required_step "browser_preflight" run_step_browser_preflight
    register_required_step "browser_auth_setup" run_step_browser_auth_setup
    register_required_step "terraform_static_guardrails" run_step_terraform_static_guardrails
    register_required_step "staging_runtime_smoke" run_step_staging_runtime_smoke
    if [ "${STAGING_ONLY:-0}" = "1" ]; then
        register_required_step "admin_broadcast" append_staging_only_production_skip_step "admin_broadcast"
        register_required_step "billing_health_last_activity" append_staging_only_production_skip_step "billing_health_last_activity"
        register_required_step "audit_timeline" append_staging_only_production_skip_step "audit_timeline"
        register_required_step "status_runtime" append_staging_only_production_skip_step "status_runtime"
        register_required_step "ses_inbound" append_staging_only_production_skip_step "ses_inbound"
        register_required_step "canary_customer_loop" append_staging_only_production_skip_step "canary_customer_loop"
        register_required_step "canary_outside_aws" append_staging_only_production_skip_step "canary_outside_aws"
        register_required_step "stripe_webhook_signature_matrix_idempotency" append_staging_only_production_skip_step "stripe_webhook_signature_matrix_idempotency"
        register_required_step "test_clock" append_staging_only_production_skip_step "test_clock"
        register_required_step "tenant_isolation" append_staging_only_production_skip_step "tenant_isolation"
        register_required_step "signup_abuse" append_staging_only_production_skip_step "signup_abuse"
        register_required_step "browser_signup_paid" append_staging_only_production_skip_step "browser_signup_paid"
        register_required_step "browser_portal_cancel" append_staging_only_production_skip_step "browser_portal_cancel"
        return 0
    fi
    register_required_step "admin_broadcast" run_paid_beta_rc_rust_step "admin_broadcast" "admin_broadcast_failed" "1" "\"$CARGO_BIN\" test -p api --test auth_admin admin_broadcast_test:: -- --ignored"
    register_required_step "billing_health_last_activity" run_paid_beta_rc_rust_step "billing_health_last_activity" "billing_health_last_activity_failed" "1" "\"$CARGO_BIN\" test -p api --test platform pg_customer_repo_test:: && \"$CARGO_BIN\" test -p api --test platform tenants_test::"
    register_required_step "audit_timeline" run_paid_beta_rc_rust_step "audit_timeline" "audit_timeline_failed" "1" "\"$CARGO_BIN\" test -p api --test auth_admin admin_audit_view_test:: -- --ignored && \"$CARGO_BIN\" test -p api --test auth_admin admin_token_audit_test:: -- --ignored"
    register_required_step "status_runtime" run_paid_beta_rc_rust_step "status_runtime" "status_runtime_failed" "0" "\"$CARGO_BIN\" test -p api --test platform onboarding_test::status_response_uses_region_not_deployment_field_names"
    register_required_step "ses_inbound" run_step_paid_beta_rc_ses_inbound
    register_required_step "canary_customer_loop" run_step_paid_beta_rc_canary_customer_loop
    register_required_step "canary_outside_aws" run_delegated_command_step "canary_outside_aws" "canary_outside_aws_failed" "" bash "$OUTSIDE_AWS_HEALTH_SCRIPT"
    register_required_step "stripe_webhook_signature_matrix_idempotency" run_paid_beta_rc_rust_step "stripe_webhook_signature_matrix_idempotency" "stripe_webhook_signature_matrix_idempotency_failed" "0" "\"$CARGO_BIN\" test -p api --test billing stripe_webhook_signature_test:: && \"$CARGO_BIN\" test -p api --test billing stripe_webhook_event_matrix_test:: && \"$CARGO_BIN\" test -p api --test billing stripe_webhook_idempotency_test::"
    register_required_step "test_clock" run_step_paid_beta_rc_test_clock
    register_required_step "tenant_isolation" run_paid_beta_rc_rust_step "tenant_isolation" "tenant_isolation_failed" "0" "\"$CARGO_BIN\" test -p api --test platform tenant_isolation_proptest::tenant_isolation_proptest_route_family"
    register_required_step "signup_abuse" run_paid_beta_rc_rust_step "signup_abuse" "signup_abuse_failed" "0" "\"$CARGO_BIN\" test -p api --test platform signup_abuse_test::"
    register_required_step "browser_signup_paid" run_step_paid_beta_rc_browser_signup_paid
    register_required_step "browser_portal_cancel" run_step_paid_beta_rc_browser_portal_cancel
}

emit_paid_beta_step_registry_json() {
    REGISTERED_STEP_NAMES=()
    STEP_REGISTRY_MODE="collect"
    visit_paid_beta_rc_step_registry || return $?
    local names_encoded sections_encoded step_name section
    local sections=()
    for step_name in "${REGISTERED_STEP_NAMES[@]}"; do
        section="$(rc_section_for_step_name "$step_name")" || {
            echo "ERROR: paid-beta RC step has no section mapping: $step_name" >&2
            return 2
        }
        sections+=("$section")
    done
    names_encoded="$(printf '%s\x1f' "${REGISTERED_STEP_NAMES[@]:-}")"
    sections_encoded="$(printf '%s\x1f' "${sections[@]:-}")"
    NAMES="$names_encoded" SECTIONS="$sections_encoded" python3 - <<'PY'
import json
import os

def decode(key):
    raw = os.environ.get(key, "")
    if raw == "":
        return []
    parts = raw.split("\x1f")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts

names = decode("NAMES")
sections = decode("SECTIONS")
payload = {
    "steps": [
        {"name": name, "section": int(sections[idx])}
        for idx, name in enumerate(names)
    ]
}
print(json.dumps(payload, indent=2))
PY
}

validate_only_steps() {
    parse_only_steps_csv || return $?
    [ "${#ONLY_STEP_NAMES[@]}" -eq 0 ] && return 0
    REGISTERED_STEP_NAMES=()
    STEP_REGISTRY_MODE="collect"
    visit_paid_beta_rc_step_registry || return $?
    local requested
    for requested in "${ONLY_STEP_NAMES[@]}"; do
        if ! registry_contains_step "$requested"; then
            echo "ERROR: unknown --only-steps value '$requested'" >&2
            return 2
        fi
    done
}
run_paid_beta_rc_rust_step() {
    local step_name="$1" fail_reason="$2" classify_skip_as_secret_missing="$3" command="$4"
    local start_ms end_ms elapsed output="" exit_code=0 log_path
    start_ms="$(_ms_now)"
    output="$(
        cd "$REPO_ROOT/infra"
        apply_rc_step_env_scope paid_beta_local_db_rust
        bash -lc "$command" 2>&1
    )" || exit_code=$?
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
    if [ "$exit_code" -eq "$TEST_INBOX_PREREQ_SKIP_EXIT_CODE" ]; then
        local skip_reason
        skip_reason="$(canonical_canary_customer_loop_skip_reason_from_log "$log_path" || true)"
        if [ -n "$skip_reason" ]; then
            append_step "canary_customer_loop" "skip" "$skip_reason" "$elapsed"
            return 0
        fi
    fi
    # Distinguish harness-env gaps (admin-key resolution drifted, admin endpoint
    # 401/403 on cleanup, signup endpoint unreachable from this host) from real
    # customer-path defects. The live Lambda canary is the authoritative
    # customer-loop signal — its CloudWatch Errors metric is the actual
    # alerting source. This in-process invocation is a harness-side rehearsal.
    if _log_matches_env_gap_pattern "$log_path" \
            'admin tenant cleanup returned HTTP 401' \
            'admin tenant cleanup returned HTTP 403' \
            'admin_call.*returned HTTP 401' \
            'admin_call.*returned HTTP 403' \
            'ADMIN_KEY missing' \
            'signup.*Could not resolve host' \
            'signup.*Connection refused' \
            'curl: \(28\)' \
            'curl: \(6\)' \
            'curl: \(7\)'; then
        append_step "canary_customer_loop" "external_secret_missing" "canary_customer_loop_env_gap" "$elapsed"
        return 0
    fi
    append_step "canary_customer_loop" "fail" "canary_customer_loop_failed" "$elapsed"
    return "$exit_code"
}
stripe_key_is_live_mode() {
    local stripe_key="$1"
    [[ "$stripe_key" == sk_live_* || "$stripe_key" == rk_live_* ]]
}
run_step_paid_beta_rc_test_clock() {
    local start_ms end_ms elapsed exit_code=0 stripe_key="" stripe_key_status=0
    local log_path status reason
    start_ms="$(_ms_now)"
    log_path="$(_step_log_path test_clock)"
    stripe_key="$(resolve_paid_beta_rc_test_clock_stripe_key)" || stripe_key_status=$?
    if [ "$stripe_key_status" -ne 0 ]; then
        end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
        case "$stripe_key_status" in
            2) reason="credentialed_env_file_parse_failed" ;;
            3) reason="credentialed_env_file_missing" ;;
            *) reason="credentialed_test_clock_stripe_key_missing" ;;
        esac
        printf 'ERROR: unable to resolve Stripe test key for paid-beta-rc test_clock: %s\n' "$reason" >"$log_path"
        append_step "test_clock" "external_secret_missing" "$reason" "$elapsed"
        return 2
    fi
    if stripe_key_is_live_mode "$stripe_key"; then
        end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
        printf 'ERROR: resolved Stripe key is live-mode; paid-beta-rc test_clock requires a test-mode key\n' >"$log_path"
        append_step "test_clock" "fail" "paid_beta_rc_test_clock_live_key_rejected" "$elapsed"
        return 1
    fi
    {
        printf 'Delegated command:'
        printf ' %q' bash "$STRIPE_VALIDATION_SCRIPT" --test-clock
        printf '\n'
    } >"$log_path"
    env STRIPE_SECRET_KEY="$stripe_key" bash "$STRIPE_VALIDATION_SCRIPT" --test-clock >>"$log_path" 2>&1 || exit_code=$?
    end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
    if [ "$exit_code" -eq 0 ]; then
        status="pass"
        reason=""
    else
        status="fail"
        reason="test_clock_failed"
    fi
    append_step "test_clock" "$status" "$reason" "$elapsed"
    [ "$exit_code" -eq 0 ] && return 0
    return "$exit_code"
}
run_required_paid_beta_rc_steps() {
    if [ "${#ONLY_STEP_NAMES[@]}" -eq 0 ]; then
        STEP_REGISTRY_MODE="execute"
        visit_paid_beta_rc_step_registry
        return 0
    fi
    local requested
    STEP_REGISTRY_MODE="execute_one"
    for requested in "${ONLY_STEP_NAMES[@]}"; do
        CURRENT_ONLY_STEP="$requested"
        visit_paid_beta_rc_step_registry
    done
    CURRENT_ONLY_STEP=""
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
            pass|skipped|skip)
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
    if [ "$LIST_PAID_BETA_STEPS" = "1" ]; then
        emit_paid_beta_step_registry_json
        return $?
    fi
    resolve_mode
    RESOLVED_SHA="$(resolve_optional_sha)"
    prepare_mode_requirements "$start_ms" || return 1
    if [ "$MODE" = "paid_beta_rc" ]; then
        validate_only_steps || return $?
        run_required_paid_beta_rc_steps
    else
        execute_required_step run_step_cargo_tests
        execute_required_step run_step_backend_launch_gate "$RESOLVED_SHA"
    fi
    emit_final_result "$start_ms"
}
if [[ "${__RUN_FULL_BACKEND_VALIDATION_SOURCED:-0}" != "1" ]]; then
    run_full_backend_validation "$@"
fi
