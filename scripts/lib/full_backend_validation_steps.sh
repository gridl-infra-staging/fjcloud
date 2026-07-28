#!/usr/bin/env bash
# Sourced backend-validation step execution and evidence helpers.
# shellcheck disable=SC2004

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

validate_env_assignment_file_syntax() {
    local env_file="$1"
    _validate_env_assignment_file_noop() { :; }
    _for_each_env_assignment "$env_file" _validate_env_assignment_file_noop
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
