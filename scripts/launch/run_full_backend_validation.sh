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
source "$REPO_ROOT/scripts/lib/full_backend_validation_steps.sh"
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
FULL_VM_LIFECYCLE_SCRIPT="${FULL_VALIDATION_FULL_VM_LIFECYCLE_SCRIPT:-$REPO_ROOT/scripts/validate_full_vm_lifecycle_prod.sh}"
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
        register_required_step "prod_full_vm_lifecycle" append_staging_only_production_skip_step "prod_full_vm_lifecycle"
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
    register_required_step "prod_full_vm_lifecycle" run_step_paid_beta_rc_prod_full_vm_lifecycle
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
# Narrow adapter around the delegated-step seam that runs the prod VM lifecycle
# owner in launch-gate-safe data-plane mode. It requires a readable credential
# env file (a prod-mutating row must classify as external_secret_missing rather
# than run without secrets), forwards it as FJCLOUD_SECRET_FILE, and lands the
# lifecycle bundle under a per-step RC evidence directory.
validate_prod_full_vm_lifecycle_credential_env() {
    local env_file="$1"
    local log_path="$2"
    local api_url="" api_status=0 admin_key="" admin_status=0

    if ! validate_env_assignment_file_syntax "$env_file" >"$log_path" 2>&1; then
        return 2
    fi

    api_url="$(read_env_value_from_file "$env_file" "API_URL")" || api_status=$?
    if [ "$api_status" -ne 0 ] || [ -z "$api_url" ]; then
        printf 'ERROR: prod_full_vm_lifecycle requires API_URL in credential env file: %s\n' "$env_file" >"$log_path"
        return 3
    fi

    admin_status=0
    admin_key="$(read_env_value_from_file "$env_file" "ADMIN_KEY")" || admin_status=$?
    if [ "$admin_status" -eq 0 ] && [ -n "$admin_key" ]; then
        return 0
    fi
    admin_status=0
    admin_key="$(read_env_value_from_file "$env_file" "FLAPJACK_ADMIN_KEY")" || admin_status=$?
    if [ "$admin_status" -eq 0 ] && [ -n "$admin_key" ]; then
        return 0
    fi

    printf 'ERROR: prod_full_vm_lifecycle requires ADMIN_KEY or FLAPJACK_ADMIN_KEY in credential env file: %s\n' "$env_file" >"$log_path"
    return 4
}

run_step_paid_beta_rc_prod_full_vm_lifecycle() {
    local start_ms end_ms elapsed evidence_dir log_path validate_status=0 reason
    start_ms="$(_ms_now)"
    log_path="$(_step_log_path prod_full_vm_lifecycle)"
    if [ -z "$CREDENTIAL_ENV_FILE" ] || [ ! -f "$CREDENTIAL_ENV_FILE" ] || [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
        printf 'ERROR: credential env file not readable: %s\n' "${CREDENTIAL_ENV_FILE:-<unset>}" >"$log_path"
        end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
        append_step "prod_full_vm_lifecycle" "external_secret_missing" "credentialed_prod_full_vm_lifecycle_env_file_missing" "$elapsed"
        return 2
    fi
    validate_prod_full_vm_lifecycle_credential_env "$CREDENTIAL_ENV_FILE" "$log_path" || validate_status=$?
    if [ "$validate_status" -ne 0 ]; then
        end_ms="$(_ms_now)"; elapsed=$((end_ms - start_ms))
        case "$validate_status" in
            2) reason="credentialed_prod_full_vm_lifecycle_env_file_parse_failed" ;;
            3) reason="credentialed_prod_full_vm_lifecycle_api_url_missing" ;;
            4) reason="credentialed_prod_full_vm_lifecycle_admin_key_missing" ;;
            *) reason="credentialed_prod_full_vm_lifecycle_env_gap" ;;
        esac
        append_step "prod_full_vm_lifecycle" "external_secret_missing" "$reason" "$elapsed"
        return 2
    fi
    evidence_dir="$ARTIFACT_DIR/prod_full_vm_lifecycle"
    mkdir -p "$evidence_dir"
    run_delegated_command_step "prod_full_vm_lifecycle" "prod_full_vm_lifecycle_failed" "" \
        env FJCLOUD_SECRET_FILE="$CREDENTIAL_ENV_FILE" STAGE5_EVIDENCE_DIR="$evidence_dir" \
        bash "$FULL_VM_LIFECYCLE_SCRIPT" data-plane
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
